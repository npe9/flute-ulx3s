// uart.hc -- 16550 UART for ULX3S (MEM_UART @ 0xC0000000, 32-bit register stride).
// Soft RX ring: 16550 FIFO is ~16 deep; UartPut must not drop pending keys
// (Vi paint / echo). Software XON/XOFF: UartXonXoff(1) default.
// RTS/CTS: UartRtsCts soft stub (no-op on the FTDI link).
#define MEM_UART  0xC0000000
#define UART_BASE MEM_UART
#define UART_THR  (UART_BASE+0)
#define UART_RBR  (UART_BASE+0)
#define UART_LSR  (UART_BASE+20)   // register index 5 * 4 bytes
#define UART_XON  0x11
#define UART_XOFF 0x13
// Piped smokes blast ~2KiB before the guest drains; 16550 FIFO is ~16.
#define HC_RX_CAP 4096
U8 g_hc_rx[HC_RX_CAP];
I64 g_hc_rh;
I64 g_hc_rt;
// Publish the soft ring to the host-slot table so trap.hc TrapUartHwDrain can
// drain IRQs into the same buffer the polled UartRxDrain uses.
*(I64 *)(MEM_HOST_SLOTS+0x20) = g_hc_rx;
*(I64 *)(MEM_HOST_SLOTS+0x28) = &g_hc_rh;
*(I64 *)(MEM_HOST_SLOTS+0x30) = &g_hc_rt;
*(I64 *)(MEM_HOST_SLOTS+0x38) = HC_RX_CAP;
I64 UartFc = 1;
I64 UartTxPaused = 0;
// Framed multi-channel UART (seed/frame.hc). Default off — raw REPL.
I64 g_uart_mux;
I64 UartHwFc = 0;
// Optional PutCh post-hook (console.hc VtCapture). FrameSend uses UartPut — bypasses.
U0 (*g_uart_putc_hook)(I64 ch);
U0 UartRxInit()
{
  g_hc_rh = 0;
  g_hc_rt = 0;
  UartTxPaused = 0;
}

I64 UartFcGet()
{
  return UartFc;
}

U0 UartXonXoff(I64 on)
{
  UartFc = on != 0;
  if (!on)
    UartTxPaused = 0;
}

I64 UartRtsCtsGet()
{
  return UartHwFc;
}
// Soft stub: no RTS/CTS wired on ULX3S FTDI UART.
U0 UartRtsCts(I64 on)
{
  UartHwFc = on != 0;
}

U0 UartFcNote(I64 ch)
{
  if (!UartFc)
    return;
  if (ch == UART_XOFF)
    UartTxPaused = 1;
  else if (ch == UART_XON)
    UartTxPaused = 0;
}

I64 UartFcIsCtrl(I64 ch)
{
  if (!UartFc)
    return 0;
  if (ch == UART_XON || ch == UART_XOFF)
    return 1;
  return 0;
}
// Pull 16550 RX into soft ring. XON/XOFF update pause only (not enqueued).
// Full ring: break (leave byte in FIFO) — never spin / never drop silently here.
U0 UartRxDrain()
{
  I64 ch, n;
  PUSHFD;
  CLI;
  while (*(U8 *)UART_LSR & 1) {
    n = (g_hc_rh + 1) & (HC_RX_CAP - 1);
    // Leave byte in 16550 if soft ring is full (never drop after RBR read).
    if (n == g_hc_rt)
      break;
    ch = *(U8 *)UART_RBR;
    if (UartFcIsCtrl(ch)) {
      UartFcNote(ch);
      continue;
    }
    g_hc_rx[g_hc_rh] = ch;
    g_hc_rh = n;
  }
  POPFD;
}

U0 UartFcPoll()
{
  UartRxDrain();
}

U0 UartPut(I64 ch)
{
  UartRxDrain();
  while (UartFc && UartTxPaused)
    UartRxDrain();
  while (!(*(U8 *)UART_LSR & 0x20)) {
    UartRxDrain();
  }
  *(U8 *)UART_THR = ch;
}

// onlcr: translate "\n" to "\r\n" on output.  The REPL prints LF only, which
// staircases in a raw serial terminal.  Flag so a future TtyRaw can disable
// it; text paths go through PutCh (binary frame senders use UartPut directly
// and bypass translation).
I64 g_uart_onlcr = 1;
U0 PutCh(I64 ch)
{
  if (ch == '\n' && g_uart_onlcr)
    UartPut('\r');
  UartPut(ch);
  if (g_uart_putc_hook)
    (*g_uart_putc_hook)(ch);
}

U0 UartStr(U8 *s)
{
  if (!s)
    return;
  while (*s)
    PutCh (*s++);
}

U0 PutS(U8 *s)
{
  UartStr(s);
}

I64 UartRxReady()
{
  UartRxDrain();
  return g_hc_rh != g_hc_rt;
}

I64 UartGet()
{
  I64 ch;
  while (1) {
    UartRxDrain();
    if (g_hc_rh != g_hc_rt) {
      ch = g_hc_rx[g_hc_rt];
      g_hc_rt = (g_hc_rt + 1) & (HC_RX_CAP - 1);
      return ch;
    }
  }
  return 0;
}

I64 HcUartGet()
{
  return UartGet();
}
// Drain any queued RX during AOT boot before Help/Sys.
U0 UartRxBootstrap()
{
  I64 idle, guard, n0, n1;
  idle = 0;
  guard = 0;
  n0 = g_hc_rh;
  while (guard++ < 131072) {
    UartRxDrain();
    n1 = g_hc_rh;
    if (*(U8 *)UART_LSR & 1)
      idle = 0;
    else {
      idle++;
      // Ring still growing → keep draining (piped regression after boot gate).
      if (n1 != n0) {
        n0 = n1;
        idle = 0;
      }
      if (idle >= 16)
        break;
    }
  }
}

I64 HcTermKeyGet()
{
  return UartGet();
}

I64 HcUartTry()
{
  I64 ch;
  UartRxDrain();
  if (g_hc_rh == g_hc_rt)
    return -1;
  ch = g_hc_rx[g_hc_rt];
  g_hc_rt = (g_hc_rt + 1) & (HC_RX_CAP - 1);
  return ch;
}
/* Push one byte back onto the soft RX ring (TermParseByte Esc-meta cancel). */
U0 HcUartUnget(I64 ch)
{
  I64 prev;
  prev = (g_hc_rt - 1) & (HC_RX_CAP - 1);
  if (prev == g_hc_rh)
    return;
  g_hc_rx[prev] = ch;
  g_hc_rt = prev;
}
