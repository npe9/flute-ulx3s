# Software for the ULX3S Flute SoC (bare-metal, linked at 0x8000_0000)

RISCV_PREFIX ?= riscv64-unknown-elf-
CC      := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy

ARCH    := -march=rv32imac_zicsr -mabi=ilp32
CFLAGS  := $(ARCH) -Os -ffreestanding -nostdlib -nostartfiles
LDFLAGS := $(ARCH) -nostdlib -T link.ld -Wl,--build-id=none

PROGS   := hello memtest minimal

all: $(addsuffix .bin, $(PROGS))

%.elf: %.c crt0.S uart.h link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) crt0.S $< -o $@

%.bin: %.elf
	$(OBJCOPY) -O binary $< $@

clean:
	rm -f $(addsuffix .elf, $(PROGS)) $(addsuffix .bin, $(PROGS))

.PHONY: all clean
