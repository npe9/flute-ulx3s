# TempleOS/RV32 bare-metal monitor for ULX3S Flute SoC

HOLYC      ?= /Users/npe/src/templeos-cursor-riscv/holyc-riscv
TOS_REPO   ?= /Users/npe/src/templeos-cursor-riscv
PREFIX     ?= riscv64-unknown-elf-
CC         := $(PREFIX)gcc
LD         := $(PREFIX)ld
OBJCOPY    := $(PREFIX)objcopy

MARCH      := rv32ima_zicsr
MABI       := ilp32

CFLAGS     := -march=$(MARCH) -mabi=$(MABI) -mcmodel=medany -O2 -g \
              -nostdlib -ffreestanding -fno-builtin -Wall -Wextra

all: build/hello/hello_ulx3s.bin build/monitor/monitor.bin

.PRECIOUS: build/hello/hello_ulx3s.elf build/monitor/monitor.elf

build/hello/hello_ulx3s.elf: hello_ulx3s.hc crt0_ulx3s.S link_ulx3s.ld
	mkdir -p build/hello
	$(HOLYC) --target rv32 hello_ulx3s.hc -o build/hello/blob.bin
	( cd build/hello && \
	  $(CC) $(CFLAGS) -c ../../crt0_ulx3s.S -o crt0.o && \
	  $(OBJCOPY) -I binary -O elf32-littleriscv blob.bin blob_in.o && \
	  $(LD) -m elf32lriscv -T ../../link_ulx3s.ld -nostdlib --no-warn-mismatch \
	        -o hello_ulx3s.elf crt0.o blob_in.o )

build/hello/hello_ulx3s.bin: build/hello/hello_ulx3s.elf
	$(OBJCOPY) -O binary $< $@

build/monitor/monitor.elf: monitor.hc crt0_ulx3s.S link_ulx3s.ld
	mkdir -p build/monitor
	$(HOLYC) --target rv32 monitor.hc -o build/monitor/blob.bin
	( cd build/monitor && \
	  $(CC) $(CFLAGS) -c ../../crt0_ulx3s.S -o crt0.o && \
	  $(OBJCOPY) -I binary -O elf32-littleriscv blob.bin blob_in.o && \
	  $(LD) -m elf32lriscv -T ../../link_ulx3s.ld -nostdlib --no-warn-mismatch \
	        -o monitor.elf crt0.o blob_in.o )

build/monitor/monitor.bin: build/monitor/monitor.elf
	$(OBJCOPY) -O binary $< $@

# ---- Full HolyC REPL --------------------------------------------------------

REPL_ROOT   := build/ulx3s_repl_root
REPL_BLOB   := build/ulx3s_repl.blob.bin
REPL_MAP    := build/ulx3s_repl.map
REPL_TRAP_H := build/ulx3s_trap_vec_off.hc

ULX3S_REPL_SRCS := ulx3s_repl/ulx3s_memmap.hc \
                   ulx3s_repl/ulx3s_start.hc \
                   ulx3s_repl/ulx3s_uart.hc \
                   ulx3s_repl/ulx3s_mem.hc \
                   ulx3s_repl/ulx3s_fs.hc \
                   ulx3s_repl/ulx3s_trap.hc \
                   ulx3s_repl/jit.hc

# The board header is derived from the elaboration-time SoC manifest
# (../build/soc-memory-map.json), which the Bluespec design emits via
# messageM from the same declarative table the AXI fabric decodes -- the
# map of the ACTUAL elaborated hardware, not a parsed copy.  The rule
# below regenerates it (re-elaborating the FPGA if needed).
FLUTE_MAP_SRCS := ../build/soc-memory-map.json \
                  ../src/Top.v \
                  ../Makefile

../build/soc-memory-map.json:
	$(MAKE) -C .. manifest

repl: $(REPL_BLOB)

BOARD_H := $(REPL_ROOT)/bootstrap/seed/ulx3s_board.hc

# Symlink the upstream bootstrap tree and overlay the ULX3S-specific files.
# The target is a REAL stamp file, not the symlinked repl.hc: a symlink's
# mtime is its target's, which defeats prerequisite checking for the copied
# overlay files (a stale jit.hc once survived an edit exactly this way).
$(REPL_ROOT)/.setup-stamp: $(ULX3S_REPL_SRCS) $(FLUTE_MAP_SRCS) scripts/gen_board_hc.py
	@rm -rf $(REPL_ROOT)
	@mkdir -p $(REPL_ROOT)
	cp -R -s $(TOS_REPO)/bootstrap $(REPL_ROOT)/bootstrap
	@rm $(REPL_ROOT)/bootstrap/seed/MemMapSelected.hc \
	    $(REPL_ROOT)/bootstrap/seed/mem.hc \
	    $(REPL_ROOT)/bootstrap/seed/fs.hc \
	    $(REPL_ROOT)/bootstrap/seed/trap.hc \
	    $(REPL_ROOT)/bootstrap/hc_repl/uart.hc \
	    $(REPL_ROOT)/bootstrap/hc_repl/start.hc \
	    $(REPL_ROOT)/bootstrap/hc_repl/jit.hc \
	    $(REPL_ROOT)/bootstrap/hc_repl/seed_embed.hc
	@cp ulx3s_repl/ulx3s_memmap.hc $(REPL_ROOT)/bootstrap/seed/MemMapSelected.hc
	@cp ulx3s_repl/ulx3s_mem.hc     $(REPL_ROOT)/bootstrap/seed/mem.hc
	@cp ulx3s_repl/ulx3s_fs.hc      $(REPL_ROOT)/bootstrap/seed/fs.hc
	@cp ulx3s_repl/ulx3s_trap.hc    $(REPL_ROOT)/bootstrap/seed/trap.hc
	@cp ulx3s_repl/ulx3s_uart.hc    $(REPL_ROOT)/bootstrap/hc_repl/uart.hc
	@cp ulx3s_repl/ulx3s_start.hc   $(REPL_ROOT)/bootstrap/hc_repl/start.hc
	@cp ulx3s_repl/jit.hc          $(REPL_ROOT)/bootstrap/hc_repl/jit.hc
	@# Regenerate seed_embed.hc so the embedded seed files use ULX3S addresses
	@# (e.g., MEMFS_BASE=0x81000000) instead of the upstream QEMU-virt values.
	@# GEN_MAX_EMBED=96 keeps MemfsSeed ~5 KB: the full ~100 KB seed hashes
	@# through the I64-emulated FNV multiply at ~2.7k cycles/B, which is tens
	@# of minutes of Bluesim per boot (and slow on the FPGA too).
	@cd $(REPL_ROOT)/bootstrap/hc_repl && GEN_MAX_EMBED=96 GEN_FULL_EMBED=0 python3 gen_embed.py
	@touch $@

# Derived board header for MemMap; -- always re-derived (via .force), but the
# file is only replaced when its CONTENT changes so the blob is not needlessly
# recompiled.  --prev-blob is the previous build's blob, so the image-extent
# field may lag one build (advisory).
$(BOARD_H): $(FLUTE_MAP_SRCS) scripts/gen_board_hc.py
	@python3 scripts/gen_board_hc.py --manifest ../build/soc-memory-map.json \
	    --flute .. --prev-blob $(REPL_BLOB) -o $@.tmp
	@cmp -s $@.tmp $@ 2>/dev/null && rm -f $@.tmp || mv $@.tmp $@

$(REPL_BLOB): $(REPL_ROOT)/.setup-stamp $(BOARD_H)
	@mkdir -p build
	@# Refresh the derived board header (image extent from the previous
	@# build's blob; cmp-guarded so an unchanged file keeps its mtime).
	@python3 scripts/gen_board_hc.py --manifest ../build/soc-memory-map.json \
	    --flute .. --prev-blob $(REPL_BLOB) -o $(BOARD_H).tmp
	@cmp -s $(BOARD_H).tmp $(BOARD_H) 2>/dev/null && rm -f $(BOARD_H).tmp || mv $(BOARD_H).tmp $(BOARD_H)
	@# Two-pass TRAP_VEC_OFF: repl.hc includes
	@# /bootstrap/hc_repl/trap_vec_off.hc, which upstream leaves as a stale
	@# leftover from a different build (0x5CEFC).  Feed the previous pass's
	@# real offset in so mtvec lands on TrapVec, then recompile once (the
	@# constant is the same width, so the offset is stable across passes).
	@if [ -f $(REPL_TRAP_H) ]; then \
	    cmp -s $(REPL_TRAP_H) $(REPL_ROOT)/bootstrap/hc_repl/trap_vec_off.hc || { \
	      echo "[repl] updating TRAP_VEC_OFF from previous build"; \
	      rm -f $(REPL_ROOT)/bootstrap/hc_repl/trap_vec_off.hc; \
	      cp $(REPL_TRAP_H) $(REPL_ROOT)/bootstrap/hc_repl/trap_vec_off.hc; \
	    } \
	fi
	HOLYC_INCLUDE_ROOT=$(abspath $(REPL_ROOT)) \
	HOLYC_MAP=$(abspath $(REPL_MAP)) \
	  $(HOLYC) --target rv32 $(REPL_ROOT)/bootstrap/hc_repl/repl.hc -o $(REPL_BLOB)
	python3 $(TOS_REPO)/bootstrap/hc_repl/patch_imports.py \
	  $(REPL_BLOB) $(REPL_MAP) $(REPL_TRAP_H)
	@off_new=$$(grep -oE '0x[0-9a-fA-F]+' $(REPL_TRAP_H) | head -1); \
	off_in=$$(grep -oE '0x[0-9a-fA-F]+' $(REPL_ROOT)/bootstrap/hc_repl/trap_vec_off.hc | head -1); \
	if [ "$$off_new" != "$$off_in" ]; then \
	  echo "[repl] TRAP_VEC_OFF changed $$off_in -> $$off_new, second pass"; \
	  rm -f $(REPL_ROOT)/bootstrap/hc_repl/trap_vec_off.hc; \
	  cp $(REPL_TRAP_H) $(REPL_ROOT)/bootstrap/hc_repl/trap_vec_off.hc; \
	  HOLYC_INCLUDE_ROOT=$(abspath $(REPL_ROOT)) \
	  HOLYC_MAP=$(abspath $(REPL_MAP)) \
	    $(HOLYC) --target rv32 $(REPL_ROOT)/bootstrap/hc_repl/repl.hc -o $(REPL_BLOB); \
	  python3 $(TOS_REPO)/bootstrap/hc_repl/patch_imports.py \
	    $(REPL_BLOB) $(REPL_MAP) $(REPL_TRAP_H); \
	fi

$(TOS_REPO)/bootstrap/hc_repl/seed_embed.hc:
	$(MAKE) -C $(TOS_REPO) repl-payload

clean:
	rm -rf build

.PHONY: all clean repl
