#ifndef UART_H
#define UART_H

typedef unsigned int  u32;
typedef unsigned char u8;

#define UART_BASE 0xC0000000ul
#define REG_RBR   0
#define REG_THR   0
#define REG_IER   1
#define REG_LCR   3
#define REG_LSR   5

static inline void uart_putc (char c)
{
    volatile u32 *uart = (volatile u32 *) UART_BASE;
    while ((uart [REG_LSR] & 0x20) == 0) { }
    uart [REG_THR] = (u32) c;
}

static inline void uart_puts (const char *s)
{
    while (*s) uart_putc (*s++);
}

static inline u32 uart_getc (void)
{
    volatile u32 *uart = (volatile u32 *) UART_BASE;
    while ((uart [REG_LSR] & 0x01) == 0) { }
    return uart [REG_RBR] & 0xff;
}

static inline void uart_init (void)
{
    volatile u32 *uart = (volatile u32 *) UART_BASE;
    uart [REG_LCR] = 0x03;    // 8N1
    uart [REG_IER] = 0x00;    // polling only
}

#endif
