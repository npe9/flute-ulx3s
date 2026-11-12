// SPDX-License-Identifier: GPL-2.0
/*
 * MAX11120-MAX11128 (the ULX3S's MAX11125: 8 channels, 12 bits) as an IIO ADC, one channel per
 * read in Manual mode.  From the datasheet (Analog Devices, MAX11120-MAX11128):
 *   - 16-bit words; DIN is sampled on the rising SCLK edge, DOUT changes on the falling edge, so
 *     SPI mode 3 (checked on the board: mode 0 reads every word one bit late);
 *   - bit 15 = 0 selects ADC Mode Control: SCAN [14:11], CHSEL [10:7], RESET [6:5], PM [4:3],
 *     CHAN_ID [2], SWCNV [1]; bit 15 = 1 with [14:11] selects the other registers (Table 1);
 *   - Manual mode (SCAN 0001, external clock): the frame that names a channel converts it, and
 *     its result comes out in the next frame; with CHAN_ID set it is [15:12] channel,
 *     [11:0] data.
 * Board check (lx45b, test/adc_test.c -DSEQ3): Manual CHSEL 7..0 answered channels 7..0 in the
 * following frames.
 *
 * The SoC's SPI host (sifive,spi0 compatible, src/AXI4_SPI.bsv) moves 8-bit frames, so a word is
 * two bytes with the chip select held across them.  The reference is the ULX3S's 3.3 V supply
 * (default "vref-mv" 3300; set the property if a board differs).
 */
#include <linux/module.h>
#include <linux/of.h>
#include <linux/spi/spi.h>
#include <linux/iio/iio.h>
#include <linux/mutex.h>

#define MAX1112X_RESET_ALL   0x0040            /* SCAN 0000 (keep mode), RESET 10 */
#define MAX1112X_CONFIG      0x8000            /* external single-ended reference, no echo */
#define MAX1112X_UNIPOLAR    0x8800            /* all single-ended */
#define MAX1112X_BIPOLAR     0x9000            /* none */
#define MAX1112X_MANUAL(ch)  (0x0800 | ((ch) << 7) | 0x0004)   /* SCAN 0001, CHSEL, CHAN_ID */

struct max1112x {
	struct spi_device *spi;
	struct mutex lock;
	u32 vref_mv;
	u8 tx[2] __aligned(IIO_DMA_MINALIGN);
	u8 rx[2];
};

static int max1112x_word(struct max1112x *st, u16 w, u16 *r)
{
	struct spi_transfer t = { .tx_buf = st->tx, .rx_buf = st->rx, .len = 2 };
	int ret;

	st->tx[0] = w >> 8;
	st->tx[1] = w & 0xff;
	ret = spi_sync_transfer(st->spi, &t, 1);
	if (!ret && r)
		*r = (st->rx[0] << 8) | st->rx[1];
	return ret;
}

static int max1112x_read(struct max1112x *st, int ch, int *val)
{
	u16 r;
	int ret;

	mutex_lock(&st->lock);
	ret = max1112x_word(st, MAX1112X_MANUAL(ch), NULL);
	if (!ret)
		ret = max1112x_word(st, 0x0000, &r);   /* SCAN 0000: no change, clocks the result out */
	mutex_unlock(&st->lock);
	if (ret)
		return ret;
	if ((r >> 12) != ch)
		return -EIO;
	*val = r & 0xfff;
	return 0;
}

static int max1112x_read_raw(struct iio_dev *indio_dev, struct iio_chan_spec const *chan,
			     int *val, int *val2, long mask)
{
	struct max1112x *st = iio_priv(indio_dev);
	int ret;

	switch (mask) {
	case IIO_CHAN_INFO_RAW:
		ret = max1112x_read(st, chan->channel, val);
		return ret ? ret : IIO_VAL_INT;
	case IIO_CHAN_INFO_SCALE:
		*val = st->vref_mv;
		*val2 = 12;
		return IIO_VAL_FRACTIONAL_LOG2;
	default:
		return -EINVAL;
	}
}

#define MAX1112X_CHAN(n) {						\
	.type = IIO_VOLTAGE, .indexed = 1, .channel = (n),		\
	.info_mask_separate = BIT(IIO_CHAN_INFO_RAW),			\
	.info_mask_shared_by_type = BIT(IIO_CHAN_INFO_SCALE),		\
}
static const struct iio_chan_spec max1112x_channels[] = {
	MAX1112X_CHAN(0), MAX1112X_CHAN(1), MAX1112X_CHAN(2), MAX1112X_CHAN(3),
	MAX1112X_CHAN(4), MAX1112X_CHAN(5), MAX1112X_CHAN(6), MAX1112X_CHAN(7),
};

static const struct iio_info max1112x_info = {
	.read_raw = max1112x_read_raw,
};

static int max1112x_probe(struct spi_device *spi)
{
	struct iio_dev *indio_dev;
	struct max1112x *st;
	int ret;

	indio_dev = devm_iio_device_alloc(&spi->dev, sizeof(*st));
	if (!indio_dev)
		return -ENOMEM;
	st = iio_priv(indio_dev);
	st->spi = spi;
	mutex_init(&st->lock);
	st->vref_mv = 3300;
	of_property_read_u32(spi->dev.of_node, "vref-mv", &st->vref_mv);

	spi->mode = SPI_MODE_3;
	spi->bits_per_word = 8;
	ret = spi_setup(spi);
	if (ret)
		return ret;
	ret = max1112x_word(st, MAX1112X_RESET_ALL, NULL);
	if (!ret)
		ret = max1112x_word(st, MAX1112X_CONFIG, NULL);
	if (!ret)
		ret = max1112x_word(st, MAX1112X_UNIPOLAR, NULL);
	if (!ret)
		ret = max1112x_word(st, MAX1112X_BIPOLAR, NULL);
	if (ret)
		return ret;

	indio_dev->name = "max11125";
	indio_dev->info = &max1112x_info;
	indio_dev->modes = INDIO_DIRECT_MODE;
	indio_dev->channels = max1112x_channels;
	indio_dev->num_channels = ARRAY_SIZE(max1112x_channels);
	return devm_iio_device_register(&spi->dev, indio_dev);
}

static const struct of_device_id max1112x_of_match[] = {
	{ .compatible = "maxim,max11125" },
	{ }
};
MODULE_DEVICE_TABLE(of, max1112x_of_match);

static const struct spi_device_id max1112x_id[] = {
	{ "max11125" },
	{ }
};
MODULE_DEVICE_TABLE(spi, max1112x_id);

static struct spi_driver max1112x_driver = {
	.driver = {
		.name = "max1112x",
		.of_match_table = max1112x_of_match,
	},
	.probe = max1112x_probe,
	.id_table = max1112x_id,
};
module_spi_driver(max1112x_driver);

MODULE_DESCRIPTION("MAX11120-MAX11128 ADC, manual mode");
MODULE_LICENSE("GPL");
