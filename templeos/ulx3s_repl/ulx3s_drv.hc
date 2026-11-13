// ulx3s_drv.hc -- ULX3S board drivers for the HolyC REPL: the MCP7940N RTC (I2C), the buttons and
// DIP switches, the audio jack's tone generator, the MAX11125 ADC, the ESP32 (reset, download
// mode, SYNC over uart1), power-off and reconfigure.
// Included from jit.hc (after print/str/mem), registered in JitInit.
//
// The same blob boots on SoCs without these devices (the 25 MHz main build, Bluesim), so nothing
// here touches a device at boot: each call looks its base up in the live SoC Info device table
// (src/SoC_Info.bsv, records at 0xC0003100) and says so when the device is missing.  Clocks come
// from SoC Info CPU_HZ and TIMER_HZ, not from the generated header.
//
// Register maps: src/Board_IO.v (i2c0 = OpenCores I2C master, gpio1 = BTN/SW, POWER and RECONF
// from lx44) and src/Audio.v.  RTC registers: Microchip DS20005010J.
//
// REPL arguments are masked to 32 bits (or less): JIT calls can carry a garbage high half.

#define BRD_SOCINFO     0xC0003000
#define BRD_DEV_I2C0    9
#define BRD_DEV_GPIO1   10
#define BRD_DEV_AUDIO   11
#define BRD_DEV_SPI2    12
#define BRD_DEV_UART1   13

U32 BrdRd(U32 a)
{
  return *(U32 *)a;
}

// Low word of the CLINT mtime (TIMER_HZ), read over the bus.
U32 BrdTimeLo()
{
  return *(U32 *)MEM_MTIME;
}

U0 BrdWr(U32 a, U32 v)
{
  *(U32 *)a = v;
}

U32 BrdCpuHz()
{
  return BrdRd(BRD_SOCINFO + 0x10);
}

// mtime rate.  Bitstreams before lx44 report CPU_HZ here, but mtime runs at 25 MHz on every
// SYS_CLK_HZ build (Near_Mem_IO_AXI4), so a TIMER_HZ equal to a CPU_HZ other than 25 MHz is that
// old value.
U32 BrdTimerHz()
{
  U32 t = BrdRd(BRD_SOCINFO + 0x14);
  if (t == BrdCpuHz() && t != 25000000)
    return 25000000;
  return t;
}

// Base of SoC Info device `id`, 0 when this bitstream has none.
U32 BrdDev(I64 id)
{
  U32 n, off, r, i;
  if (BrdRd(BRD_SOCINFO) != 0x464C5331)
    return 0;
  n = BrdRd(BRD_SOCINFO + 0x1C);
  off = BrdRd(BRD_SOCINFO + 0x20);
  if (n > 64)
    return 0;
  for (i = 0; i < n; i++) {
    r = BRD_SOCINFO + off + i * 32;
    if (BrdRd(r) == (id & 0xFF))
      return BrdRd(r + 8);
  }
  return 0;
}

U32 BrdNeed(I64 id, U8 *what)
{
  U32 b = BrdDev(id);
  if (!b) {
    UartStr(what);
    UartStr(": not in this bitstream\n");
  }
  return b;
}

// Busy-wait `ms` milliseconds on the CLINT timer, a second at a time (so the 32-bit tick
// difference never wraps).
U0 Sleep(I64 ms)
{
  U32 per, t0, n, k;
  per = BrdTimerHz() / 1000;
  if (!per)
    per = 25000;
  n = ms & 0xFFFFFF;
  while (n) {
    k = n;
    if (k > 1000)
      k = 1000;
    t0 = BrdTimeLo();
    while (BrdTimeLo() - t0 < per * k) {
    }
    n -= k;
  }
}

// ---------------- I2C (OpenCores master at i2c0) ----------------
U32 g_i2c;

I64 I2cInit()
{
  U32 p;
  g_i2c = BrdNeed(BRD_DEV_I2C0, "i2c0");
  if (!g_i2c)
    return 0;
  p = BrdCpuHz() / 500000 - 1;              // SCL = clk / (5 * (PRER + 1)) = 100 kHz
  BrdWr(g_i2c + 0x08, 0);
  BrdWr(g_i2c + 0x00, p & 0xFF);
  BrdWr(g_i2c + 0x04, (p >> 8) & 0xFF);
  BrdWr(g_i2c + 0x08, 0x80);
  return 1;
}

// One command (CR bits), waits up to ~50 ms; returns SR, 0x80 (no ack) when the bus is stuck.
U32 I2cCmd(U32 c)
{
  U32 t0, lim, sr;
  lim = BrdTimerHz() / 20;
  BrdWr(g_i2c + 0x10, c);
  t0 = BrdTimeLo();
  while (BrdRd(g_i2c + 0x10) & 2) {
    if (BrdTimeLo() - t0 > lim) {
      UartStr("i2c: stuck, bus released\n");
      BrdWr(g_i2c + 0x08, 0);
      BrdWr(g_i2c + 0x08, 0x80);
      return 0x80;
    }
  }
  sr = BrdRd(g_i2c + 0x10);
  BrdWr(g_i2c + 0x10, 1);
  return sr;
}

I64 I2cSend(U32 b, U32 c)
{
  BrdWr(g_i2c + 0x0C, b & 0xFF);
  return !(I2cCmd(c | 0x10) & 0x80);
}

// Register `ra` of 7-bit device `dev`; -1 when it does not answer.
I64 I2cRd(I64 dev, I64 ra)
{
  U32 d = dev & 0x7F;
  if (!g_i2c && !I2cInit())
    return -1;
  if (!(I2cSend(d << 1, 0x80) && I2cSend(ra & 0xFF, 0) && I2cSend((d << 1) | 1, 0x80))) {
    I2cCmd(0x40);
    return -1;
  }
  I2cCmd(0x20 | 0x08 | 0x40);                // RD, no ack, STO
  return BrdRd(g_i2c + 0x0C) & 0xFF;
}

I64 I2cWr(I64 dev, I64 ra, I64 v)
{
  U32 d = dev & 0x7F;
  if (!g_i2c && !I2cInit())
    return 0;
  if (I2cSend(d << 1, 0x80) && I2cSend(ra & 0xFF, 0) && I2cSend(v & 0xFF, 0x40))
    return 1;
  I2cCmd(0x40);
  return 0;
}

// ---------------- RTC (MCP7940N at 0x6F) ----------------
#define RTC_ADDR 0x6F
U8 *g_wday[8] = {"?", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};

I64 RtcBcd(I64 b)
{
  return ((b >> 4) & 15) * 10 + (b & 15);
}

I64 RtcToBcd(I64 v)
{
  return ((v / 10) << 4) | (v % 10);
}

// 24-hour value of RTCHOUR (either mode).
I64 RtcHour(I64 h)
{
  I64 v;
  if (!(h & 0x40))
    return RtcBcd(h & 0x3F);
  v = RtcBcd(h & 0x1F) % 12;
  if (h & 0x20)
    v += 12;
  return v;
}

// Prints the time; returns seconds since midnight, -1 when the RTC does not answer.
I64 RtcShow()
{
  I64 s, mi, h, wk, d, mo, y;
  s = I2cRd(RTC_ADDR, 0);
  if (s < 0) {
    UartStr("rtc: no answer at 0x6f\n");
    return -1;
  }
  mi = I2cRd(RTC_ADDR, 1);
  h = I2cRd(RTC_ADDR, 2);
  wk = I2cRd(RTC_ADDR, 3);
  d = I2cRd(RTC_ADDR, 4);
  mo = I2cRd(RTC_ADDR, 5);
  y = I2cRd(RTC_ADDR, 6);
  Print("20%02d-%02d-%02d %02d:%02d:%02d %s", RtcBcd(y), RtcBcd(mo & 0x1F), RtcBcd(d & 0x3F),
        RtcHour(h), RtcBcd(mi & 0x7F), RtcBcd(s & 0x7F), g_wday[wk & 7]);
  if (!(s & 0x80))
    UartStr("  (oscillator stopped: RtcSet starts it)");
  if (!(wk & 0x08))
    UartStr("  (battery backup off: RtcSet turns it on)");
  if (wk & 0x10)
    UartStr("  (PWRFAIL: power was lost)");
  UartStr("\n");
  return RtcHour(h) * 3600 + RtcBcd(mi & 0x7F) * 60 + RtcBcd(s & 0x7F);
}

// Sets date and time (24-hour, years 2000-2099), weekday computed (1 = Sunday, as Linux's
// rtc-ds1307 uses), battery backup on, oscillator started.  Datasheet note: stop the
// oscillator and wait for OSCRUN to clear before loading new values.
I64 RtcSet(I64 y, I64 mo, I64 d, I64 h, I64 mi, I64 s)
{
  I64 yy, w, i, t;
  U8 *sak = "032503514624";
  y &= 0xFFFF; mo &= 0xFF; d &= 0xFF; h &= 0xFF; mi &= 0xFF; s &= 0xFF;
  if (y < 2000 || y > 2099 || mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || s > 59) {
    UartStr("RtcSet(year, month, day, hour, min, sec): out of range\n");
    return 0;
  }
  yy = y;
  if (mo < 3)
    yy--;
  w = (yy + yy / 4 - yy / 100 + yy / 400 + sak[mo - 1] - '0' + d) % 7 + 1;
  if (!I2cWr(RTC_ADDR, 0, 0)) {
    UartStr("rtc: no answer at 0x6f\n");
    return 0;
  }
  for (i = 0; i < 100; i++) {
    t = I2cRd(RTC_ADDR, 3);
    if (t >= 0 && !(t & 0x20))
      break;
    Sleep(1);
  }
  I2cWr(RTC_ADDR, 1, RtcToBcd(mi));
  I2cWr(RTC_ADDR, 2, RtcToBcd(h));          // bit 6 = 0: 24-hour mode
  I2cWr(RTC_ADDR, 3, 0x08 | w);             // VBATEN; the write clears PWRFAIL
  I2cWr(RTC_ADDR, 4, RtcToBcd(d));
  I2cWr(RTC_ADDR, 5, RtcToBcd(mo));
  I2cWr(RTC_ADDR, 6, RtcToBcd(y - 2000));
  I2cWr(RTC_ADDR, 0, 0x80 | RtcToBcd(s));   // ST: oscillator on
  return 1;
}

// Alarm 0 on a seconds match `secs` (1-59) from now: MFP pulses low, which powers the board back
// on after PowerOff.  ALMPOL 0, ALM0MSK 000; the ALM0WKDAY write clears ALM0IF.
I64 RtcAlarmIn(I64 secs)
{
  I64 s, wk, ctl, at;
  secs &= 0xFF;
  if (secs < 1 || secs > 59) {
    UartStr("RtcAlarmIn(secs): 1-59\n");
    return 0;
  }
  s = I2cRd(RTC_ADDR, 0);
  wk = I2cRd(RTC_ADDR, 3);
  ctl = I2cRd(RTC_ADDR, 7);
  if (s < 0 || wk < 0 || ctl < 0) {
    UartStr("rtc: no answer at 0x6f\n");
    return 0;
  }
  if (!(s & 0x80))
    UartStr("rtc: oscillator stopped, the alarm will not fire (RtcSet)\n");
  at = RtcToBcd((RtcBcd(s & 0x7F) + secs) % 60);
  I2cWr(RTC_ADDR, 7, ctl & ~0x10);
  I2cWr(RTC_ADDR, 0x0A, at);
  I2cWr(RTC_ADDR, 0x0D, wk & 7);
  I2cWr(RTC_ADDR, 7, (ctl & ~0x40) | 0x10);
  return 1;
}

U0 RtcAlarmOff()
{
  I64 ctl, wk;
  ctl = I2cRd(RTC_ADDR, 7);
  wk = I2cRd(RTC_ADDR, 3);
  if (ctl < 0 || wk < 0) {
    UartStr("rtc: no answer at 0x6f\n");
    return;
  }
  I2cWr(RTC_ADDR, 7, ctl & ~0x50);
  I2cWr(RTC_ADDR, 0x0D, wk & 7);
}

// ---------------- buttons and DIP switches (gpio1) ----------------
U8 *g_btn_name[7] = {"PWR", "FIRE1", "FIRE2", "UP", "DOWN", "LEFT", "RIGHT"};

// [6:0] 1 = pressed: 0 PWR, 1 FIRE1 (also the SoC reset), 2 FIRE2, 3 UP, 4 DOWN, 5 LEFT, 6 RIGHT.
I64 Btns()
{
  U32 b = BrdNeed(BRD_DEV_GPIO1, "gpio1");
  if (!b)
    return 0;
  return BrdRd(b + 4) & 0x7F;
}

// [3:0] 1 = on.
I64 Sws()
{
  U32 b = BrdNeed(BRD_DEV_GPIO1, "gpio1");
  if (!b)
    return 0;
  return BrdRd(b + 8) & 0xF;
}

// Waits up to `ms` (0 = forever, at most 120000) for a button press (20 ms debounce) and its release; prints
// the name, returns its bit number, -1 on timeout.  FIRE1 resets the SoC, so it never returns 1.
I64 BtnWait(I64 ms)
{
  U32 b, v, t0, lim, i;
  b = BrdNeed(BRD_DEV_GPIO1, "gpio1");
  if (!b)
    return -1;
  ms &= 0xFFFFF;
  if (ms > 120000)
    ms = 120000;                            // keeps the tick count in 32 bits
  lim = (BrdTimerHz() / 1000) * ms;
  while (BrdRd(b + 4) & 0x7F) {
  }
  t0 = BrdTimeLo();
  while (1) {
    v = BrdRd(b + 4) & 0x7F;
    if (v) {
      Sleep(20);
      if ((BrdRd(b + 4) & 0x7F) == v)
        break;
    }
    if (lim && BrdTimeLo() - t0 > lim)
      return -1;
  }
  for (i = 0; i < 7; i++)
    if (v & (1 << i))
      break;
  while (BrdRd(b + 4) & 0x7F) {
  }
  Sleep(20);
  UartStr(g_btn_name[i]);
  UartStr("\n");
  return i;
}

// ---------------- sound (Audio tone generator) ----------------
I64 g_snd_vol = 2;                          // 0 mute .. 8 full scale; low: it drives headphones

U32 SndBase()
{
  U32 b = BrdNeed(BRD_DEV_AUDIO, "audio");
  if (b && BrdRd(b) != 0x41554431) {
    UartStr("audio: bad id\n");
    return 0;
  }
  return b;
}

// Square wave at `hz` (0 = off).  The generator's half period is 16 bits, so a tone below
// CPU_HZ / 131072 (381 Hz at 50 MHz) plays octaves higher.
U0 SndHz(I64 hz)
{
  U32 b, half;
  b = SndBase();
  if (!b)
    return;
  hz &= 0xFFFFF;
  if (!hz) {
    BrdWr(b + 4, BrdRd(b + 4) & ~2);
    return;
  }
  half = BrdCpuHz() / 2 / hz;
  while (half > 65536)
    half >>= 1;
  if (half < 2)
    half = 2;
  BrdWr(b + 0x10, half - 1);
  BrdWr(b + 8, g_snd_vol);
  BrdWr(b + 4, BrdRd(b + 4) | 2);
}

// Frequency in milli-Hz of TempleOS note `ona` (Ona2Freq: 440/32 * 2^(ona/12); 60 = A 440).
I64 Ona2MilliHz(I64 ona)
{
  I64 k, f;
  k = ona % 12;
  if (k == 0) f = 13750;
  else if (k == 1) f = 14568;
  else if (k == 2) f = 15434;
  else if (k == 3) f = 16352;
  else if (k == 4) f = 17324;
  else if (k == 5) f = 18354;
  else if (k == 6) f = 19445;
  else if (k == 7) f = 20602;
  else if (k == 8) f = 21827;
  else if (k == 9) f = 23125;
  else if (k == 10) f = 24500;
  else f = 25957;
  return f << (ona / 12);
}

// TempleOS Snd: note `ona` (0 = off), at the SndVol volume.
U0 Snd(I64 ona)
{
  I64 m;
  ona &= 0x7F;
  if (!ona) {
    SndHz(0);
    return;
  }
  m = Ona2MilliHz(ona);
  SndHz((m + 500) / 1000);
}

// Volume 0 (mute) .. 8 (full scale); returns the previous one.
I64 SndVol(I64 v)
{
  I64 old = g_snd_vol;
  U32 b;
  v &= 0xF;
  if (v > 8)
    v = 8;
  g_snd_vol = v;
  b = SndBase();
  if (b && (BrdRd(b + 4) & 2))
    BrdWr(b + 8, v);
  return old;
}

U0 Beep()
{
  Snd(62);
  Sleep(200);
  Snd(0);
}

// ---------------- power and reconfigure (gpio1 0x10 / 0x14, lx44 on) ----------------
// shutdown pin high: the board's power switch turns off.  Wake: PWR button, re-plugging US1,
// the RTC alarm (RtcAlarmIn).  While US1 powers the board the FT231X's D18 holds it on.
U0 BrdPowerOff()
{
  U32 b = BrdNeed(BRD_DEV_GPIO1, "gpio1");
  if (!b)
    return;
  UartStr("power off\n");
  Sleep(50);
  BrdWr(b + 0x10, 0x504F4646);              // "POFF", a full-word write
  Sleep(1000);
  UartStr("still on: no POWER register in this bitstream (before lx44), or the board is "
          "powered from US1, where the FT231X (D18) holds it on\n");
}

U0 PowerOffFor(I64 secs)
{
  if (RtcAlarmIn(secs))
    BrdPowerOff();
}

// PROGRAMN low: the FPGA reloads its configuration from flash.
U0 Reconf()
{
  U32 b = BrdNeed(BRD_DEV_GPIO1, "gpio1");
  if (!b)
    return;
  UartStr("reconfiguring from flash\n");
  Sleep(50);
  BrdWr(b + 0x14, 0x52454346);              // "RECF"
  Sleep(1000);
  UartStr("still here: no RECONF register in this bitstream (before lx44)\n");
}

// ---------------- ADC (MAX11125 on spi2, src/AXI4_SPI.bsv: SiFive SPI registers) ----------------
// MAX11120-MAX11128 datasheet: 16-bit words, DIN sampled on the rising SCLK edge and DOUT moving on
// the falling edge (SPI mode 3).  Manual mode (SCAN 0001, CHAN_ID): the frame naming a channel
// converts it, the next frame carries [15:12] channel, [11:0] data.  The host moves 8-bit frames,
// so a word is two under CSMODE HOLD.  Checked on the board with test/adc_test.c -DSEQ3.
U32 g_adc;

// One 16-bit word under one chip select; the reply, or -1 when the host does not answer.
I64 AdcWord(I64 w)
{
  U32 t0, lim, v, hi, i;
  lim = BrdTimerHz() / 100;
  BrdWr(g_adc + 0x18, 2);                   // CSMODE HOLD
  BrdWr(g_adc + 0x48, (w >> 8) & 0xFF);
  BrdWr(g_adc + 0x48, w & 0xFF);
  hi = 0;
  for (i = 0; i < 2; i++) {
    t0 = BrdTimeLo();
    while ((v = BrdRd(g_adc + 0x4C)) & 0x80000000) {
      if (BrdTimeLo() - t0 > lim) {
        BrdWr(g_adc + 0x18, 0);
        UartStr("adc: spi2 does not answer\n");
        return -1;
      }
    }
    hi = (hi << 8) | (v & 0xFF);
  }
  BrdWr(g_adc + 0x18, 0);                   // CSMODE AUTO: chip select up
  return hi;
}

I64 AdcInit()
{
  g_adc = BrdNeed(BRD_DEV_SPI2, "spi2");
  if (!g_adc)
    return 0;
  BrdWr(g_adc + 0x00, 1);                   // SCKDIV 1: clk / 4 (12.5 MHz at 50 MHz)
  BrdWr(g_adc + 0x04, 3);                   // SCKMODE 3: CPOL 1, CPHA 1
  BrdWr(g_adc + 0x10, 0);                   // CSID 0
  while (!(BrdRd(g_adc + 0x4C) & 0x80000000))
    ;                                       // drain RX
  if (AdcWord(0x0040) < 0)                  // reset all registers
    return 0;
  AdcWord(0x8000);                          // configuration: external single-ended reference
  AdcWord(0x8800);                          // unipolar: all single-ended
  AdcWord(0x9000);                          // bipolar: none
  return 1;
}

// Channel `ch` (0-7): 12-bit result, -1 on failure.
I64 AdcRd(I64 ch)
{
  I64 r;
  ch &= 0xFF;
  if (ch > 7) {
    UartStr("adc: channels 0-7\n");
    return -1;
  }
  if (!AdcInit())
    return -1;
  AdcWord(0x0804 | (ch << 7));              // Manual, CHSEL ch, CHAN_ID
  r = AdcWord(0);                           // SCAN 0000: no change; clocks the result out
  if (r < 0)
    return -1;
  if ((r >> 12) != ch) {
    Print("adc: reply 0x%04X is for channel %d\n", r, r >> 12);
    return -1;
  }
  return r & 0xFFF;
}

// All eight channels, raw and in millivolts (3.3 V reference, 4096 steps).
U0 AdcShow()
{
  I64 ch, v;
  for (ch = 0; ch < 8; ch++) {
    v = AdcRd(ch);
    if (v < 0)
      return;
    Print("ain%d %4d  %4d mV\n", ch, v, v * 3300 / 4096);
  }
}

// ---------------- ESP32 (EN/TX/STRAP at gpio1 0x0C, its UART0 on uart1 at 115200) ----------------
// src/Top.v holds the ESP32's GPIO0 low, so a released ESP32 can only run its ROM bootloader.
// gpio1 0x0C: [0] EN (0 = held in reset), [1] its TX level, [2] STRAP: GPIO2 (sd_d0) low while
// the SD card is deselected.  GPIO0 low with GPIO2 low = download mode (esptool's protocol);
// with GPIO2 high (its pull-up) the ROM tries the SPI flash with HSPI pins and stops.
// From the host, scripts/esp32_bridge.py bridges esptool to it through the board.

U0 Esp32Off()
{
  U32 g = BrdNeed(BRD_DEV_GPIO1, "gpio1");
  if (g)
    BrdWr(g + 0x0C, 0);
}

// Reset into the ROM's download mode; 1 when its TX line is then driven (it is running).
I64 Esp32Download()
{
  U32 g = BrdNeed(BRD_DEV_GPIO1, "gpio1");
  if (!g)
    return 0;
  BrdWr(g + 0x0C, 0);
  Sleep(50);
  BrdWr(g + 0x0C, 4);                       // GPIO2 low, EN still low
  Sleep(5);
  BrdWr(g + 0x0C, 5);                       // EN rises: download mode
  Sleep(50);
  BrdWr(g + 0x0C, 1);                       // let GPIO2 go
  Sleep(50);
  return (BrdRd(g + 0x0C) >> 1) & 1;
}

// esptool's SYNC (SLIP framed) to the ROM; 1 when it answers.  Call Esp32Download() first.
I64 Esp32Sync()
{
  U32 u, t0, lim, i, k, n, st;
  U8 hdr[13];
  u = BrdNeed(BRD_DEV_UART1, "uart1");
  if (!u)
    return 0;
  hdr[0] = 0xC0; hdr[1] = 0x00; hdr[2] = 0x08; hdr[3] = 0x24; hdr[4] = 0x00;
  hdr[5] = 0; hdr[6] = 0; hdr[7] = 0; hdr[8] = 0;
  hdr[9] = 0x07; hdr[10] = 0x07; hdr[11] = 0x12; hdr[12] = 0x20;
  lim = BrdTimerHz() / 10;
  while (BrdRd(u + 0x14) & 1)
    BrdRd(u);                               // drop what the ROM printed
  for (k = 0; k < 5; k++) {
    for (i = 0; i < 45; i++) {
      while (!(BrdRd(u + 0x14) & 0x20))
        ;
      if (i < 13)
        BrdWr(u, hdr[i]);
      else if (i < 45)
        BrdWr(u, 0x55);
    }
    while (!(BrdRd(u + 0x14) & 0x20))
      ;
    BrdWr(u, 0xC0);
    // the reply starts C0 01 08
    st = 0;
    n = 0;
    t0 = BrdTimeLo();
    while (BrdTimeLo() - t0 < lim) {
      if (BrdRd(u + 0x14) & 1) {
        i = BrdRd(u) & 0xFF;
        n++;
        if (st == 0 && i == 0xC0) st = 1;
        else if (st == 1 && i == 0x01) st = 2;
        else if (st == 2 && i == 0x08) {
          Print("esp32: SYNC answered (try %d)\n", k + 1);
          return 1;
        } else st = (i == 0xC0);
      }
    }
  }
  UartStr("esp32: no SYNC reply\n");
  return 0;
}

// ---------------- HDMI: CEC, hot plug detect, Utility (gpio1 0x18) ----------------
// [0] CEC_LOW pulls the CEC line low (open drain); read [8] CEC line, [9] HPD, [10] Utility.
U32 g_hdmi;
U32 g_cec_tpu;                              // timer ticks per microsecond
U32 g_cec_t;                                // the current bit's start (timer ticks)

U32 HdmiBase()
{
  if (!g_hdmi)
    g_hdmi = BrdNeed(BRD_DEV_GPIO1, "gpio1");
  g_cec_tpu = BrdTimerHz() / 1000000;
  return g_hdmi;
}

// Prints the three lines; returns [0] HPD (a sink is connected), [1] CEC (1 = idle), [2] Utility.
I64 HdmiStat()
{
  U32 r;
  if (!HdmiBase())
    return -1;
  r = BrdRd(g_hdmi + 0x18);
  Print("hdmi: HPD %d  CEC %d  Utility %d\n", (r >> 9) & 1, (r >> 8) & 1, (r >> 10) & 1);
  return ((r >> 9) & 1) | (((r >> 8) & 1) << 1) | (((r >> 10) & 1) << 2);
}

I64 CecLine()
{
  return (BrdRd(g_hdmi + 0x18) >> 8) & 1;
}

U0 CecUntil(I64 us)
{
  while (BrdTimeLo() - g_cec_t < us * g_cec_tpu)
    ;
}

// The pin itself: pull low for 50 us (shorter than any CEC bit), it must read 0; release, it must
// read 1 again.  1 = both.
I64 CecSelf()
{
  I64 lo, hi;
  if (!HdmiBase())
    return 0;
  g_cec_t = BrdTimeLo();
  BrdWr(g_hdmi + 0x18, 1);
  CecUntil(50);
  lo = CecLine();
  BrdWr(g_hdmi + 0x18, 0);
  CecUntil(150);
  hi = CecLine();
  return lo == 0 && hi == 1;
}

// One data bit: low 0.6 ms (1) or 1.5 ms (0), 2.4 ms in all.  Returns the line at 1.05 ms: a
// follower acknowledges by holding a 1 low there.
I64 CecBit(I64 b)
{
  I64 s = 0;
  BrdWr(g_hdmi + 0x18, 1);
  if (b) {
    CecUntil(600);
    BrdWr(g_hdmi + 0x18, 0);
    CecUntil(1050);
    s = CecLine();
  } else {
    CecUntil(1500);
    BrdWr(g_hdmi + 0x18, 0);
  }
  CecUntil(2400);
  g_cec_t += 2400 * g_cec_tpu;
  return s;
}

// The CEC polling message (a header block only) from "unregistered" (15) to logical address dst
// (0 = TV): 1 when a device there acknowledges, 0 when none does, -1 when the line is not idle.
I64 CecPoll(I64 dst)
{
  I64 i, hdr, ack;
  if (!HdmiBase())
    return -1;
  // the line must stay idle (high) for 7 bit periods first
  g_cec_t = BrdTimeLo();
  while (BrdTimeLo() - g_cec_t < 16800 * g_cec_tpu)
    if (!CecLine())
      return -1;
  g_cec_t = BrdTimeLo();
  BrdWr(g_hdmi + 0x18, 1);                  // start bit: low 3.7 ms, 4.5 ms in all
  CecUntil(3700);
  BrdWr(g_hdmi + 0x18, 0);
  CecUntil(4500);
  g_cec_t += 4500 * g_cec_tpu;
  hdr = 0xF0 | (dst & 15);
  for (i = 7; i >= 0; i--)
    CecBit((hdr >> i) & 1);
  CecBit(1);                                // EOM
  ack = CecBit(1);                          // ACK: sent as 1, pulled to 0 by the follower
  return !ack;
}

// ---------------- S/PDIF (audio 0x1C) and PCM ----------------
// S/PDIF on the jack's ring 2: pins = which of its four DAC bits carry it (0 = off, 15 = all, about
// 0.5 V into a 75 ohm coax load), sfreq = channel status sample rate (0 44.1 kHz, 2 48 kHz).  It
// carries the PCM FIFO's samples (PcmTone), not the tone generator (Snd).
U0 SpdifSet(I64 pins, I64 sfreq)
{
  U32 b = SndBase();
  if (b)
    BrdWr(b + 0x1C, (pins & 15) | ((sfreq & 15) << 8));
}

// A square wave of hz through the PCM FIFO for ms (44.1 kHz), at SndVol on the jack and full scale
// on S/PDIF.  Returns the samples written.
I64 PcmTone(I64 hz, I64 ms)
{
  U32 b = SndBase();
  I64 n, total, half, ph = 0, v;
  if (!b || hz <= 0)
    return 0;
  BrdWr(b + 0x0C, BrdCpuHz() / 44100 - 1);
  BrdWr(b + 0x08, g_snd_vol);
  half = 44100 / (2 * hz);
  if (half < 1)
    half = 1;
  total = 44100 * ms / 1000;
  for (n = 0; n < total; n++) {
    while ((BrdRd(b + 0x18) & 0x1FF) >= 250)
      ;
    v = 0x2000;
    if ((ph / half) & 1)
      v = 0xE000;
    BrdWr(b + 0x14, v | (v << 16));
    ph++;
    if (n == 64)
      BrdWr(b + 0x04, 1);                   // play once some samples are queued
  }
  while (BrdRd(b + 0x18) & 0x1FF)
    ;
  BrdWr(b + 0x04, 0);
  return total;
}

U0 BoardHelp()
{
  UartStr(
    "RtcShow()                 date and time (returns seconds since midnight)\n"
    "RtcSet(y,mo,d,h,mi,s)     set it (24 h); battery backup on, oscillator on\n"
    "RtcAlarmIn(s) RtcAlarmOff()   alarm 0, s = 1-59 seconds from now\n"
    "I2cRd(dev,reg) I2cWr(dev,reg,v)   the RTC/DDC bus (-1 / 0 = no answer)\n"
    "Btns() Sws()              buttons [6:0], DIP switches [3:0]\n"
    "BtnWait(ms)               wait for a button (0 = forever); bit number or -1\n"
    "Snd(ona) SndHz(hz) SndVol(0-8) Beep()   tone on the audio jack (Snd(0) = off)\n"
    "AdcRd(ch) AdcShow()       MAX11125 ADC: channel 0-7 (12 bits), all eight in mV\n"
    "Esp32Download() Esp32Sync() Esp32Off()   ESP32 ROM download mode, esptool SYNC\n"
    "HdmiStat() CecSelf() CecPoll(dst)   HDMI HPD/CEC/Utility; CEC pin check, poll (1 = ACK)\n"
    "SpdifSet(pins,sfreq) PcmTone(hz,ms)   S/PDIF on jack ring 2; PCM square wave\n"
    "Sleep(ms) BrdRd(addr) BrdWr(addr,v)   32-bit register access\n"
    "PowerOff() PowerOffFor(s) Reconf()\n");
}
