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

I64 main()
{
  UartPutS("ULX3S from TempleOS HolyC (rv32)\r\n");
  return 0;
}
