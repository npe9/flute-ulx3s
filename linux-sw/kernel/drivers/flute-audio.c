// SPDX-License-Identifier: GPL-2.0
/*
 * ALSA driver for the ULX3S Flute SoC audio device (src/Audio.v): a 256-sample stereo PCM FIFO and a
 * tone generator on the jack's 4-bit sigma-delta DACs.  Registers (32-bit):
 *   0x00 ID "AUD1"  0x04 CTRL [0] PCM [1] tone  0x08 VOLUME 0 (mute) .. 8  0x0C RATE clocks per sample - 1
 *   0x10 TONE  0x14 FIFO [15:0] left [31:16] right, signed  0x18 STATUS [8:0] level [16] drop [17] underrun
 * The device has no interrupt, so an hrtimer keeps the FIFO topped up from the ALSA buffer.
 * Playback only: S16_LE, 2 channels, 8-48 kHz.  "Master Playback Volume" 0-8, muted at probe.
 */
#include <linux/hrtimer.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/spinlock.h>
#include <sound/control.h>
#include <sound/core.h>
#include <sound/initval.h>
#include <sound/pcm.h>

#define FA_ID      0x00
#define FA_CTRL    0x04
#define FA_VOLUME  0x08
#define FA_RATE    0x0C
#define FA_FIFO    0x14
#define FA_STATUS  0x18
#define FA_ID_VAL  0x41554431
#define FA_DEPTH   256
#define FA_LEVEL   0x1FF
#define FA_PERIOD_NS (2 * NSEC_PER_MSEC)

struct flute_audio {
	struct snd_card *card;
	void __iomem *base;
	u32 clk_hz;
	spinlock_t lock;
	struct hrtimer timer;
	struct snd_pcm_substream *substream;  /* set while running */
	snd_pcm_uframes_t pos;                /* frames handed to the FIFO, in the buffer */
	snd_pcm_uframes_t in_period;
	u32 volume;
};

static void fa_fill(struct flute_audio *fa, bool *elapsed)
{
	struct snd_pcm_runtime *rt = fa->substream->runtime;
	u32 level = readl(fa->base + FA_STATUS) & FA_LEVEL;
	u32 room = level < FA_DEPTH ? FA_DEPTH - level : 0;

	while (room--) {
		const s16 *f = (const s16 *)(rt->dma_area + frames_to_bytes(rt, fa->pos));

		writel(((u32)(u16)f[1] << 16) | (u16)f[0], fa->base + FA_FIFO);
		if (++fa->pos >= rt->buffer_size)
			fa->pos = 0;
		if (++fa->in_period >= rt->period_size) {
			fa->in_period = 0;
			*elapsed = true;
		}
	}
}

static enum hrtimer_restart fa_timer(struct hrtimer *t)
{
	struct flute_audio *fa = container_of(t, struct flute_audio, timer);
	struct snd_pcm_substream *ss;
	bool elapsed = false;
	unsigned long flags;

	spin_lock_irqsave(&fa->lock, flags);
	ss = fa->substream;
	if (ss)
		fa_fill(fa, &elapsed);
	spin_unlock_irqrestore(&fa->lock, flags);
	if (!ss)
		return HRTIMER_NORESTART;
	if (elapsed)
		snd_pcm_period_elapsed(ss);
	hrtimer_forward_now(t, ns_to_ktime(FA_PERIOD_NS));
	return HRTIMER_RESTART;
}

static const struct snd_pcm_hardware fa_hw = {
	.info = SNDRV_PCM_INFO_INTERLEAVED | SNDRV_PCM_INFO_MMAP | SNDRV_PCM_INFO_MMAP_VALID |
		SNDRV_PCM_INFO_BLOCK_TRANSFER,
	.formats = SNDRV_PCM_FMTBIT_S16_LE,
	.rates = SNDRV_PCM_RATE_CONTINUOUS | SNDRV_PCM_RATE_8000_48000,
	.rate_min = 8000,
	.rate_max = 48000,
	.channels_min = 2,
	.channels_max = 2,
	.buffer_bytes_max = 64 * 1024,
	.period_bytes_min = 256,
	.period_bytes_max = 16 * 1024,
	.periods_min = 2,
	.periods_max = 64,
};

static int fa_open(struct snd_pcm_substream *ss)
{
	ss->runtime->hw = fa_hw;
	return 0;
}

static int fa_close(struct snd_pcm_substream *ss)
{
	return 0;
}

static int fa_prepare(struct snd_pcm_substream *ss)
{
	struct flute_audio *fa = snd_pcm_substream_chip(ss);

	writel(0, fa->base + FA_CTRL);
	writel(DIV_ROUND_CLOSEST(fa->clk_hz, ss->runtime->rate) - 1, fa->base + FA_RATE);
	writel(0, fa->base + FA_STATUS);
	fa->pos = 0;
	fa->in_period = 0;
	return 0;
}

static int fa_trigger(struct snd_pcm_substream *ss, int cmd)
{
	struct flute_audio *fa = snd_pcm_substream_chip(ss);
	bool elapsed = false;

	switch (cmd) {
	case SNDRV_PCM_TRIGGER_START:
	case SNDRV_PCM_TRIGGER_RESUME:
		spin_lock(&fa->lock);
		fa->substream = ss;
		fa_fill(fa, &elapsed);        /* prime the FIFO before playing */
		writel(1, fa->base + FA_CTRL);
		spin_unlock(&fa->lock);
		hrtimer_start(&fa->timer, ns_to_ktime(FA_PERIOD_NS), HRTIMER_MODE_REL);
		return 0;
	case SNDRV_PCM_TRIGGER_STOP:
	case SNDRV_PCM_TRIGGER_SUSPEND:
		spin_lock(&fa->lock);
		fa->substream = NULL;          /* the timer stops itself */
		writel(0, fa->base + FA_CTRL);
		spin_unlock(&fa->lock);
		return 0;
	}
	return -EINVAL;
}

static snd_pcm_uframes_t fa_pointer(struct snd_pcm_substream *ss)
{
	struct flute_audio *fa = snd_pcm_substream_chip(ss);

	return fa->pos;
}

static const struct snd_pcm_ops fa_ops = {
	.open = fa_open,
	.close = fa_close,
	.prepare = fa_prepare,
	.trigger = fa_trigger,
	.pointer = fa_pointer,
};

static int fa_vol_info(struct snd_kcontrol *k, struct snd_ctl_elem_info *u)
{
	u->type = SNDRV_CTL_ELEM_TYPE_INTEGER;
	u->count = 1;
	u->value.integer.min = 0;
	u->value.integer.max = 8;
	return 0;
}

static int fa_vol_get(struct snd_kcontrol *k, struct snd_ctl_elem_value *u)
{
	struct flute_audio *fa = snd_kcontrol_chip(k);

	u->value.integer.value[0] = fa->volume;
	return 0;
}

static int fa_vol_put(struct snd_kcontrol *k, struct snd_ctl_elem_value *u)
{
	struct flute_audio *fa = snd_kcontrol_chip(k);
	long v = u->value.integer.value[0];

	if (v < 0 || v > 8)
		return -EINVAL;
	if (v == fa->volume)
		return 0;
	fa->volume = v;
	writel(v, fa->base + FA_VOLUME);
	return 1;
}

static const struct snd_kcontrol_new fa_vol = {
	.iface = SNDRV_CTL_ELEM_IFACE_MIXER,
	.name = "Master Playback Volume",
	.info = fa_vol_info,
	.get = fa_vol_get,
	.put = fa_vol_put,
};

static int fa_probe(struct platform_device *pdev)
{
	struct flute_audio *fa;
	struct snd_card *card;
	struct snd_pcm *pcm;
	int err;

	err = snd_devm_card_new(&pdev->dev, SNDRV_DEFAULT_IDX1, "FluteAudio", THIS_MODULE,
				sizeof(*fa), &card);
	if (err < 0)
		return err;
	fa = card->private_data;
	fa->card = card;
	spin_lock_init(&fa->lock);
	fa->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(fa->base))
		return PTR_ERR(fa->base);
	if (readl(fa->base + FA_ID) != FA_ID_VAL)
		return dev_err_probe(&pdev->dev, -ENODEV, "no audio device (ID %08x)\n",
				     readl(fa->base + FA_ID));
	if (of_property_read_u32(pdev->dev.of_node, "clock-frequency", &fa->clk_hz))
		fa->clk_hz = 50000000;
	writel(0, fa->base + FA_CTRL);
	writel(0, fa->base + FA_VOLUME);    /* muted: it drives real headphones */
	fa->volume = 0;
	hrtimer_init(&fa->timer, CLOCK_MONOTONIC, HRTIMER_MODE_REL);
	fa->timer.function = fa_timer;

	err = snd_pcm_new(card, "Flute PCM", 0, 1, 0, &pcm);
	if (err < 0)
		return err;
	pcm->private_data = fa;
	strscpy(pcm->name, "Flute jack", sizeof(pcm->name));
	snd_pcm_set_ops(pcm, SNDRV_PCM_STREAM_PLAYBACK, &fa_ops);
	snd_pcm_set_managed_buffer_all(pcm, SNDRV_DMA_TYPE_VMALLOC, NULL, 0, 0);
	err = snd_ctl_add(card, snd_ctl_new1(&fa_vol, fa));
	if (err < 0)
		return err;
	strscpy(card->driver, "FluteAudio", sizeof(card->driver));
	strscpy(card->shortname, "ULX3S Flute audio", sizeof(card->shortname));
	snprintf(card->longname, sizeof(card->longname), "ULX3S Flute audio at %pR",
		 platform_get_resource(pdev, IORESOURCE_MEM, 0));
	err = snd_card_register(card);
	if (err < 0)
		return err;
	platform_set_drvdata(pdev, fa);
	return 0;
}

static void fa_remove(struct platform_device *pdev)
{
	struct flute_audio *fa = platform_get_drvdata(pdev);

	hrtimer_cancel(&fa->timer);
	writel(0, fa->base + FA_CTRL);
}

static const struct of_device_id fa_of[] = {
	{ .compatible = "ulx3s,flute-audio" },
	{ }
};
MODULE_DEVICE_TABLE(of, fa_of);

static struct platform_driver fa_driver = {
	.probe = fa_probe,
	.remove = fa_remove,
	.driver = { .name = "flute-audio", .of_match_table = fa_of },
};
module_platform_driver(fa_driver);

MODULE_DESCRIPTION("ULX3S Flute SoC audio");
MODULE_LICENSE("GPL");
