// ULX3S Flute SoC memory map for the HolyC REPL.
// 32 MB SDRAM @ 0x80000000..0x82000000; CLINT/PLIC match QEMU virt.

#define MEM_RAM        0x80000000
#define MEM_TEST       0

#define MEM_CLINT      0x02000000
#define MEM_CLINT_MTIME_OFF    0x0000BFF8
#define MEM_CLINT_MTIMECMP_OFF 0x00004000
#define MEM_MTIME      0x0200BFF8
#define MEM_MTIMECMP   0x02004000

#define MEM_PLIC       0x0C000000
#define MEM_PLIC_ENABLE_OFF    0x00002000
#define MEM_PLIC_THRESHOLD_OFF 0x00200000
#define MEM_PLIC_CLAIM_OFF     0x00200004

#define MEM_UART       0xC0000000
#define MEM_UART1      0
#define MEM_GPIO       0xC0002000
#define MEM_PRCI       0
#define MEM_ETH        0
#define MEM_VIRTIO     0
#define MEM_VIRTIO_STRIDE 0
#define MEM_FW_CFG     0

// No real RTC; point at CLINT mtime so Uptime/LogNow still tick.
#define MEM_RTC        MEM_MTIME

// Kernel phase3 Compiler.BIN embed — not present in the UART REPL image.
#define MEM_COMPILER   0

// FS base is also hardcoded in seed/fs.hc as MEMFS_BASE.
#define MEM_FS         0x81000000
#define MEM_HEAP       0x80200000
#define MEM_FB         0
#define MEM_FIXED      0x81800000
#define MEM_TRAP_SNAP  0x81800100
#define MEM_REGS_SNAP  0x81800300
#define MEM_HOST_SLOTS 0x81801000
#define MEM_STACK      0x82000000

#define MEMMAP_DRV_UART    "RVUart16550 / uart.hc"
#define MEMMAP_DRV_CLINT   "RVTimer / CLINT"
#define MEMMAP_DRV_PLIC    "RVPlicHw"
#define MEMMAP_DRV_VIRTIO  "none"
#define MEMMAP_DRV_FB      "none"
#define MEMMAP_DRV_FW_CFG  "none"
#define MEMMAP_DRV_RTC     "CLINT mtime"
#define MEMMAP_DRV_FS      "fs.hc"
#define MEMMAP_DRV_HEAP    "mem.hc"
#define MEMMAP_DRV_TRAP    "trap.hc"
#define MEMMAP_DRV_REGS    "Regs / csr.hc"
#define MEMMAP_DRV_TEST    "none"
#define MEMMAP_DRV_RAM     "ULX3S SDRAM"
