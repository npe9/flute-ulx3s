#include "uart.h"

int main (void)
{
    uart_init ();
    uart_puts ("\r\nMINIMAL OK\r\n");
    while (1)
        __asm__ volatile ("");
    return 0;
}
