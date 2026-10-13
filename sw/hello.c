#include "uart.h"

static const char hex_digits [] = "0123456789abcdef";

static void print_u32 (u32 v)
{
    char buf [9];
    for (int i = 7; i >= 0; i--) {
	buf [i] = hex_digits [v & 0xF];
	v >>= 4;
    }
    buf [8] = 0;
    uart_puts (buf);
}

int main (void)
{
    uart_init ();
    uart_puts ("\r\nHello from Flute (Bluespec RV32) on the ULX3S!\r\n");

    u32 count = 0;
    while (1) {
	uart_puts ("tick ");
	print_u32 (count++);
	uart_puts ("\r\n");
	for (u32 d = 0; d < 8; d++)
	    for (u32 i = 0; i < 1000000; i++) __asm__ volatile ("");
    }
    return 0;
}
