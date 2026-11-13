// SPDX-License-Identifier: GPL-2.0
/*
 * flute-sdh: the microSD card in native SD mode (1/4-bit, programmed I/O) on the ULX3S Flute SoC,
 * src/Sd_Host.v at 0xC000_D000 (lx48).  The host keeps one 512-byte block: a received block holds
 * the card clock until it has been read out, so multi-block reads need no DMA or second buffer.
 *
 * Read-only unless flute_sdh.writable=1 on the kernel command line: get_ro reports the card
 * write-protected, and the hardware's WPROT bit (set by reset) stays set, so the host refuses
 * CMD24/25/27/28/29/38/42/56 and never drives DAT.  The writable path is exercised only against
 * the simulator's card model.
 *
 * The pins are shared with SPI mode (spi0 + mmc_spi): only one of the two may own the card, and a
 * card that has seen CMD0 in SPI mode stays there until power is cycled.  The ESP32 must be held in
 * reset (gpio1 0x0C == 0): it is an SDIO slave on the same lines, and the host stays in SPI-mode
 * pass-through while it runs.
 */
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/clk.h>
#include <linux/mmc/host.h>
#include <linux/mmc/mmc.h>
#include <linux/mmc/sd.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/scatterlist.h>

#define SDH_ID		0x00
#define SDH_CTRL	0x04
#define SDH_ARG		0x08
#define SDH_CMD		0x0C
#define SDH_STATUS	0x10
#define SDH_RESP0	0x14
#define SDH_BLKSIZE	0x24
#define SDH_BLKCNT	0x28
#define SDH_DTMO	0x2C
#define SDH_FIFO	0x30
#define SDH_ABORT	0x34

#define CTRL_MODE	BIT(0)
#define CTRL_WIDE	BIT(1)
#define CTRL_WPROT	BIT(2)
#define CTRL_CLKEN	BIT(3)
#define CTRL_DIV(d)	((u32)(d) << 16)

#define CMD_R48		(1u << 8)
#define CMD_R136	(2u << 8)
#define CMD_NOCRC	BIT(10)
#define CMD_DATA	BIT(11)
#define CMD_WRITE	BIT(12)

#define ST_CBUSY	BIT(0)
#define ST_CDONE	BIT(1)
#define ST_CTMO		BIT(2)
#define ST_CCRC		BIT(3)
#define ST_DBUSY	BIT(4)
#define ST_DDONE	BIT(5)
#define ST_DCRC		BIT(6)
#define ST_DTMO		BIT(7)
#define ST_BUF		BIT(8)
#define ST_DAT0		BIT(9)
#define ST_WPREJ	BIT(10)
#define ST_WRERR	BIT(11)
#define ST_NATIVE	BIT(12)

static bool writable;
module_param(writable, bool, 0444);
MODULE_PARM_DESC(writable, "allow writes (simulator only; the board's card is read-only)");

struct flute_sdh {
	void __iomem *base;
	struct mmc_host *mmc;
	unsigned long sys_hz;
	u32 ctrl;
};

static u32 sdh_rd(struct flute_sdh *h, u32 off) { return readl(h->base + off); }
static void sdh_wr(struct flute_sdh *h, u32 off, u32 v) { writel(v, h->base + off); }

static void sdh_ctrl(struct flute_sdh *h)
{
	sdh_wr(h, SDH_CTRL, h->ctrl);
}

/* wait until (status & mask) == want, or any bit of stop is set; 0, or -ETIMEDOUT */
static int sdh_wait(struct flute_sdh *h, u32 mask, u32 want, u32 stop, unsigned int ms, u32 *st)
{
	unsigned long end = jiffies + msecs_to_jiffies(ms) + 1;
	unsigned int n = 0;
	u32 s;

	for (;;) {
		s = sdh_rd(h, SDH_STATUS);
		if ((s & mask) == want || (s & stop))
			break;
		if (++n >= 256) {
			n = 0;
			if (time_after(jiffies, end)) {
				s = sdh_rd(h, SDH_STATUS);
				if ((s & mask) == want || (s & stop))
					break;
				*st = s;
				return -ETIMEDOUT;
			}
			cond_resched();
		}
	}
	*st = s;
	return 0;
}

static int sdh_send(struct flute_sdh *h, struct mmc_command *cmd, u32 dflags)
{
	u32 c = cmd->opcode & 0x3f, st;
	int i, err;

	if (cmd->flags & MMC_RSP_PRESENT)
		c |= (cmd->flags & MMC_RSP_136) ? CMD_R136 : CMD_R48;
	if ((cmd->flags & MMC_RSP_PRESENT) && !(cmd->flags & MMC_RSP_CRC))
		c |= CMD_NOCRC;
	c |= dflags;

	if (!(sdh_rd(h, SDH_STATUS) & ST_NATIVE))
		return -ENOMEDIUM;		/* the ESP32 runs, or SPI mode owns the pins */
	sdh_wr(h, SDH_ARG, cmd->arg);
	sdh_wr(h, SDH_CMD, c);
	err = sdh_wait(h, ST_CBUSY, 0, 0, 1000, &st);
	if (err)
		return err;
	if (st & ST_WPREJ)
		return -EROFS;
	if (st & ST_CTMO)
		return -ETIMEDOUT;
	if (st & ST_CCRC)
		return -EILSEQ;
	if (cmd->flags & MMC_RSP_136)
		for (i = 0; i < 4; i++)
			cmd->resp[i] = sdh_rd(h, SDH_RESP0 + 4 * i);
	else
		cmd->resp[0] = sdh_rd(h, SDH_RESP0);
	if (cmd->flags & MMC_RSP_BUSY) {
		unsigned int ms = cmd->busy_timeout ? cmd->busy_timeout : 10000;

		if (sdh_wait(h, ST_DAT0, ST_DAT0, 0, ms, &st))
			return -ETIMEDOUT;
	}
	return 0;
}

static int sdh_data(struct flute_sdh *h, struct mmc_data *data)
{
	bool wr = data->flags & MMC_DATA_WRITE;
	unsigned int words = data->blksz / 4, b, i;
	struct sg_mapping_iter mi;
	u32 st, *p = NULL;
	size_t left = 0;
	int err = 0;

	sg_miter_start(&mi, data->sg, data->sg_len,
		       wr ? SG_MITER_FROM_SG : SG_MITER_TO_SG);
	for (b = 0; b < data->blocks; b++) {
		err = sdh_wait(h, ST_BUF, ST_BUF, ST_DTMO | (wr ? ST_DDONE : 0), 1000, &st);
		if (err || (st & ST_DTMO) || !(st & ST_BUF)) {
			err = (st & ST_DTMO) || err ? -ETIMEDOUT : -EIO;
			break;
		}
		for (i = 0; i < words; i++) {
			if (!left) {
				if (!sg_miter_next(&mi)) {
					err = -EINVAL;
					goto out;
				}
				p = mi.addr;
				left = mi.length / 4;
			}
			if (wr)
				sdh_wr(h, SDH_FIFO, *p++);
			else
				*p++ = sdh_rd(h, SDH_FIFO);
			left--;
		}
		data->bytes_xfered += data->blksz;
		if (!wr && (sdh_rd(h, SDH_STATUS) & ST_DCRC)) {
			err = -EILSEQ;
			break;
		}
	}
out:
	sg_miter_stop(&mi);
	if (!err && wr) {
		if (sdh_wait(h, ST_DBUSY, 0, 0, 2000, &st))
			err = -ETIMEDOUT;
		else if (st & (ST_WRERR | ST_DCRC))
			err = -EILSEQ;
		else if (st & ST_DTMO)
			err = -ETIMEDOUT;
	}
	if (err) {
		sdh_wr(h, SDH_ABORT, 0);
		data->bytes_xfered = 0;
	}
	return err;
}

static void sdh_request(struct mmc_host *mmc, struct mmc_request *mrq)
{
	struct flute_sdh *h = mmc_priv(mmc);
	struct mmc_data *data = mrq->data;
	u32 df = 0;

	if (data) {
		if (data->blksz < 4 || data->blksz > 512 || (data->blksz & 3)) {
			data->error = -EINVAL;
			mrq->cmd->error = 0;
			goto done;
		}
		sdh_wr(h, SDH_BLKSIZE, data->blksz);
		sdh_wr(h, SDH_BLKCNT, data->blocks);
		sdh_wr(h, SDH_DTMO, 0xffffff);
		df = CMD_DATA | ((data->flags & MMC_DATA_WRITE) ? CMD_WRITE : 0);
	}
	mrq->cmd->error = sdh_send(h, mrq->cmd, df);
	if (data) {
		if (mrq->cmd->error)
			sdh_wr(h, SDH_ABORT, 0);
		else
			data->error = sdh_data(h, data);
		if (data->stop)
			data->stop->error = sdh_send(h, data->stop, 0);
	}
done:
	mmc_request_done(mmc, mrq);
}

static void sdh_set_ios(struct mmc_host *mmc, struct mmc_ios *ios)
{
	struct flute_sdh *h = mmc_priv(mmc);
	u32 div = 4095;

	if (ios->clock) {
		/* f = sys / (2 (div + 1)), div >= 1 */
		div = DIV_ROUND_UP(h->sys_hz, 2 * ios->clock);
		div = clamp_t(u32, div, 2, 4096) - 1;
	}
	h->ctrl &= ~(CTRL_WIDE | CTRL_CLKEN | CTRL_DIV(0xfff));
	h->ctrl |= CTRL_DIV(div);
	if (ios->bus_width == MMC_BUS_WIDTH_4)
		h->ctrl |= CTRL_WIDE;
	if (ios->power_mode != MMC_POWER_OFF && ios->clock)
		h->ctrl |= CTRL_CLKEN;
	sdh_ctrl(h);
}

static int sdh_get_ro(struct mmc_host *mmc)
{
	return !writable;
}

static int sdh_get_cd(struct mmc_host *mmc)
{
	return 1;		/* no card-detect switch: the slot is treated as always full */
}

static int sdh_card_busy(struct mmc_host *mmc)
{
	struct flute_sdh *h = mmc_priv(mmc);

	return !(sdh_rd(h, SDH_STATUS) & ST_DAT0);
}

static const struct mmc_host_ops sdh_ops = {
	.request	= sdh_request,
	.set_ios	= sdh_set_ios,
	.get_ro		= sdh_get_ro,
	.get_cd		= sdh_get_cd,
	.card_busy	= sdh_card_busy,
};

static int sdh_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct mmc_host *mmc;
	struct flute_sdh *h;
	struct clk *clk;
	u32 hz = 50000000;
	int ret;

	mmc = devm_mmc_alloc_host(dev, sizeof(*h));
	if (!mmc)
		return -ENOMEM;
	h = mmc_priv(mmc);
	h->mmc = mmc;
	h->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(h->base))
		return PTR_ERR(h->base);
	if (sdh_rd(h, SDH_ID) != 0x53444831)
		return dev_err_probe(dev, -ENODEV, "no SD host at this address (ID %08x)\n",
				     sdh_rd(h, SDH_ID));
	clk = devm_clk_get_optional_enabled(dev, NULL);
	if (IS_ERR(clk))
		return PTR_ERR(clk);
	if (clk && clk_get_rate(clk))
		hz = clk_get_rate(clk);
	else
		of_property_read_u32(dev->of_node, "clock-frequency", &hz);
	h->sys_hz = hz;

	/* native mode, 1-bit, write-protected unless writable, clock off until the core asks */
	h->ctrl = CTRL_MODE | CTRL_DIV(4095) | (writable ? 0 : CTRL_WPROT);
	sdh_wr(h, SDH_ABORT, 0);
	sdh_ctrl(h);
	if (!(sdh_rd(h, SDH_STATUS) & ST_NATIVE))
		dev_warn(dev, "the ESP32 is running: the card is unreachable until it is held in reset\n");

	mmc->ops = &sdh_ops;
	mmc->f_min = 400000 / 4;
	mmc->f_max = min_t(u32, hz / 4, 25000000);
	mmc->ocr_avail = MMC_VDD_32_33 | MMC_VDD_33_34;
	mmc->caps = MMC_CAP_4_BIT_DATA | MMC_CAP_NONREMOVABLE;
	mmc->caps2 = MMC_CAP2_NO_SDIO | MMC_CAP2_NO_MMC;
	mmc->max_segs = 128;
	mmc->max_blk_size = 512;
	mmc->max_blk_count = 256;
	mmc->max_req_size = 512 * 256;
	mmc->max_seg_size = mmc->max_req_size;
	ret = mmc_add_host(mmc);
	if (ret)
		return ret;
	platform_set_drvdata(pdev, h);
	dev_info(dev, "native SD host, %s, f_max %u Hz\n", writable ? "writable" : "read-only",
		 mmc->f_max);
	return 0;
}

static void sdh_remove(struct platform_device *pdev)
{
	struct flute_sdh *h = platform_get_drvdata(pdev);

	mmc_remove_host(h->mmc);
	h->ctrl &= ~CTRL_CLKEN;
	sdh_ctrl(h);
}

static const struct of_device_id sdh_of_match[] = {
	{ .compatible = "flute,sd-host" },
	{ }
};
MODULE_DEVICE_TABLE(of, sdh_of_match);

static struct platform_driver sdh_driver = {
	.probe	= sdh_probe,
	.remove	= sdh_remove,
	.driver	= {
		.name		= "flute-sdh",
		.of_match_table	= sdh_of_match,
	},
};
module_platform_driver(sdh_driver);

MODULE_DESCRIPTION("ULX3S Flute SoC native SD host");
MODULE_LICENSE("GPL");
