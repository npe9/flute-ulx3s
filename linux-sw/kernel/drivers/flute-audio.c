// SPDX-License-Identifier: GPL-2.0
/*
 * ALSA driver for the ULX3S Flute SoC audio device (src/Audio.v): a 256-sample stereo PCM FIFO and a
 * tone generator on the jack's 4-bit sigma-delta DACs.  Registers (32-bit):
 *   0x00 ID "AUD1"  0x04 CTRL [0] PCM [1] tone  0x08 VOLUME 0 (mute) .. 8  0x0C RATE clocks per sample - 1
 *   0x10 TONE  0x14 FIFO [15:0] left [31:16] right, signed  0x18 STATUS [8:0] level [16] drop [17] underrun
 *   0x1C SPDIF [3:0] ring-2 pins that carry S/PDIF (0 = off) [11:8] channel status sample rate (lx47)
 * The device has no interrupt, so an hrtimer keeps the FIFO topped up from the ALSA buffer.
 * Playback only: S16_LE, 2 channels, 8-48 kHz.  "Master Playback Volume" 0-8, muted at probe.
 * "IEC958 Playback Switch" (off at probe) sends the same samples, before the volume, as S/PDIF on
 * the jack's ring 2 (a coax S/PDIF input through a 3.5 mm TRRS adapter); the channel status gives
 * 44.1, 48 or 32 kHz, else "not indicated".  On a bitstream without it the register does nothing.
 * The tone generator is also an input device with EV_SND SND_TONE / SND_BELL (like pcspkr), so the
 * console bell, KDMKTONE and a write of an EV_SND event to its /dev/input node sound it; it plays at
 * the ALSA volume (muted until that is raised).  TONE is 16 bits of half periods, so tones below
 * clk / 2^17 (381 Hz at 50 MHz) play an octave up, as often as needed.
 */
#include <linux/input.h>
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
#define FA_TONE    0x10
#define FA_FIFO    0x14
#define FA_STATUS  0x18
#define FA_SPDIF   0x1C
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
	u32 ctrl;                             /* CTRL shadow: PCM and tone share it */
	u32 spdif;                            /* IEC958 switch */
	u32 sfreq;                            /* channel status rate code of the last prepare */
	struct input_dev *beep;
};

static void fa_ctrl(struct flute_audio *fa, u32 mask, u32 val)
{
	fa->ctrl = (fa->ctrl & ~mask) | (val & mask);
	writel(fa->ctrl, fa->base + FA_CTRL);
}

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

static void fa_spdif(struct flute_audio *fa)
{
	writel((fa->spdif ? 0xF : 0) | fa->sfreq << 8, fa->base + FA_SPDIF);
}

static int fa_prepare(struct snd_pcm_substream *ss)
{
	struct flute_audio *fa = snd_pcm_substream_chip(ss);

	spin_lock_irq(&fa->lock);
	fa_ctrl(fa, 1, 0);
	spin_unlock_irq(&fa->lock);
	writel(DIV_ROUND_CLOSEST(fa->clk_hz, ss->runtime->rate) - 1, fa->base + FA_RATE);
	fa->sfreq = ss->runtime->rate == 44100 ? 0 : ss->runtime->rate == 48000 ? 2 :
		    ss->runtime->rate == 32000 ? 3 : 1;
	fa_spdif(fa);
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
		fa_ctrl(fa, 1, 1);
		spin_unlock(&fa->lock);
		hrtimer_start(&fa->timer, ns_to_ktime(FA_PERIOD_NS), HRTIMER_MODE_REL);
		return 0;
	case SNDRV_PCM_TRIGGER_STOP:
	case SNDRV_PCM_TRIGGER_SUSPEND:
		spin_lock(&fa->lock);
		fa->substream = NULL;          /* the timer stops itself */
		fa_ctrl(fa, 1, 0);
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

static int fa_iec_get(struct snd_kcontrol *k, struct snd_ctl_elem_value *u)
{
	struct flute_audio *fa = snd_kcontrol_chip(k);

	u->value.integer.value[0] = fa->spdif;
	return 0;
}

static int fa_iec_put(struct snd_kcontrol *k, struct snd_ctl_elem_value *u)
{
	struct flute_audio *fa = snd_kcontrol_chip(k);
	u32 v = !!u->value.integer.value[0];

	if (v == fa->spdif)
		return 0;
	fa->spdif = v;
	fa_spdif(fa);
	return 1;
}

static const struct snd_kcontrol_new fa_iec = {
	.iface = SNDRV_CTL_ELEM_IFACE_MIXER,
	.name = "IEC958 Playback Switch",
	.info = snd_ctl_boolean_mono_info,
	.get = fa_iec_get,
	.put = fa_iec_put,
};

/* EV_SND: value = Hz for SND_TONE (0 = off), nonzero = on (1 kHz) for SND_BELL */
static int fa_beep_event(struct input_dev *dev, unsigned int type, unsigned int code, int value)
{
	struct flute_audio *fa = input_get_drvdata(dev);
	unsigned long flags;
	u32 half = 0;

	if (type != EV_SND || (code != SND_TONE && code != SND_BELL))
		return -EINVAL;
	if (code == SND_BELL && value)
		value = 1000;
	if (value > 0 && value <= 20000) {
		half = fa->clk_hz / 2 / value;
		while (half > 65536)
			half /= 2;
	}
	spin_lock_irqsave(&fa->lock, flags);
	if (half) {
		writel(half - 1, fa->base + FA_TONE);
		fa_ctrl(fa, 2, 2);
	} else {
		fa_ctrl(fa, 2, 0);
	}
	spin_unlock_irqrestore(&fa->lock, flags);
	return 0;
}

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
	fa_ctrl(fa, 3, 0);
	writel(0, fa->base + FA_VOLUME);    /* muted: it drives real headphones */
	writel(0, fa->base + FA_SPDIF);     /* ring 2 idle */
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
	if (!err)
		err = snd_ctl_add(card, snd_ctl_new1(&fa_iec, fa));
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

	fa->beep = devm_input_allocate_device(&pdev->dev);
	if (fa->beep) {
		fa->beep->name = "ULX3S Flute beep";
		fa->beep->phys = "flute-audio/input0";
		fa->beep->id.bustype = BUS_HOST;
		fa->beep->evbit[0] = BIT_MASK(EV_SND);
		fa->beep->sndbit[0] = BIT_MASK(SND_TONE) | BIT_MASK(SND_BELL);
		fa->beep->event = fa_beep_event;
		input_set_drvdata(fa->beep, fa);
		if (input_register_device(fa->beep))
			dev_warn(&pdev->dev, "no beep input device\n");
	}
	return 0;
}

static void fa_remove(struct platform_device *pdev)
{
	struct flute_audio *fa = platform_get_drvdata(pdev);

	hrtimer_cancel(&fa->timer);
	fa_ctrl(fa, 3, 0);
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
