// ULX3S TempleOS bare-metal monitor (HolyC -> rv32 AOT)
// Loaded by the UART bootloader at 0x80000000.
U0 UartPutC(U8 c)
{
  U32 *uart = 0xC0000000;
  while ((uart[5] & 0x20) == 0) {
  }
  uart[0] = c;
}

U0 UartPutS(U8 *s)
{
  while (*s)
    UartPutC (*s++);
}

U8 UartGetC()
{
  U32 *uart = 0xC0000000;
  while ((uart[5] & 0x01) == 0) {
  }
  return uart[0] & 0xff;
}

U0 UartPutHex8(U32 v)
{
  I64 i;
  for (i = 28; i >= 0; i -= 4) {
    U8 n = (v >> i) & 0xf;
    U8 c = n < 10 ? '0' + n : 'a' + (n - 10);
    UartPutC(c);
  }
}

I64 HexDigit(U8 c)
{
  if (c >= '0' && c <= '9')
    return c - '0';
  if (c >= 'a' && c <= 'f')
    return c - 'a' + 10;
  if (c >= 'A' && c <= 'F')
    return c - 'A' + 10;
  return -1;
}

U32 ParseHex(U8 **s)
{
  U32 v = 0;
  while (1) {
    I64 d = HexDigit (**s);
    if (d < 0)
      break;
    v = (v << 4) | d;
    (*s)++;
  }
  return v;
}

U0 SkipSpace(U8 **s)
{
  while (**s == ' ' || **s == '\t')
    (*s)++;
}

U0 Jump(U32 addr)
{
  asm {
	jr a0
  }
}

I64 main()
{
  U8 buf[80];
  UartPutS("ULX3S TempleOS monitor (rv32)\r\n");
  while (1) {
    UartPutS("\r\n> ");
    I64 i = 0;
    while (1) {
      U8 c = UartGetC();
      if (c == '\r' || c == '\n')
        break;
      if (c == '\b' || c == 0x7f) {
        if (i > 0) {
          i--;
          UartPutC('\b');
          UartPutC(' ');
          UartPutC('\b');
        }
        continue;
      }
      if (i < 79) {
        buf[i++] = c;
        UartPutC(c);
      }
    }
    buf[i] = 0;
    UartPutS("\r\n");
    U8 *p = buf;
    SkipSpace(&p);
    U8 cmd = *p++;
    if (cmd == 'h' || cmd == '?') {
      UartPutS("r <addr>      read 32-bit word\r\n");
      UartPutS("w <addr> <v>  write 32-bit word\r\n");
      UartPutS("g <addr>      jump to address\r\n");
      UartPutS("h             help\r\n");
    } else if (cmd == 'r') {
      SkipSpace(&p);
      U32 addr = ParseHex(&p);
      U32 *ptr = addr;
      U32 val = *ptr;
      UartPutS("0x");
      UartPutHex8(val);
      UartPutS("\r\n");
    } else if (cmd == 'w') {
      SkipSpace(&p);
      U32 addr = ParseHex(&p);
      SkipSpace(&p);
      U32 val = ParseHex(&p);
      U32 *ptr = addr;
      *ptr = val;
      UartPutS("ok\r\n");
    } else if (cmd == 'g') {
      SkipSpace(&p);
      U32 addr = ParseHex(&p);
      UartPutS("jumping\r\n");
      Jump(addr);
    } else {
      UartPutS("?\r\n");
    }
  }
  return 0;
}
