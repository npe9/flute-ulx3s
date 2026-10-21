# ================================================================
# ULX3S Flute SoC: Bluespec Flute RV32 on the ULX3S-85F
#
#   make            : BSV -> Verilog -> Yosys -> nextpnr -> bitstream (+ RISC-V sw)
#   make program    : load bitstream into volatile SRAM
#   make run        : program SRAM and load hello.bin over the UART
#   make bootrom    : rebuild the boot ROM (boot_loader.c -> fn_read_ROM_RV32.bsvi)
#
# ================================================================

BSC     ?= $(HOME)/src/bsc/inst/bin/bsc
YOSYS   ?= yosys
NEXTPNR ?= $(CURDIR)/../bluespec-ulx3s/toolchain/nextpnr-build/nextpnr-ecp5
ECPPACK ?= $(CURDIR)/../bluespec-ulx3s/toolchain/prjtrellis-install/bin/ecppack
DEVICE  ?= 85k
# Seed 3: best of the pipe4 sweep (CACHE_SNAPSHOT netlist) at the enforced
# 25 MHz constraint.  The pipelined-cache netlist runs ~3 MHz faster than
# seam-1 and passes at far more seeds; 29.20 MHz solo (+17% margin).
SEED    ?= 3

RISCV_PREFIX ?= riscv64-unknown-elf-

# BSC primitive Verilog library (FIFO2, RegFile, ...), excluding
# file-test harnesses and modules yosys cannot parse (Load BRAMs use
# $readmemh with empty names; InoutConnect/Probe* use SV interfaces).
BSC_VERILOG_LIB := $(abspath $(dir $(BSC))../lib/Verilog)
BSC_VERILOG_FILES := $(foreach f,$(wildcard $(BSC_VERILOG_LIB)/*.v),\
	$(if $(findstring Load,$(notdir $f)),,$(if $(findstring InoutConnect,$(notdir $f)),,$(if $(findstring Probe,$(notdir $f)),,$(if $(filter main.v,$(notdir $f)),,$f)))))

BUILD := build
BDIR  := $(BUILD)/bsc
VDIR  := $(BUILD)/verilog
IDIR  := $(BUILD)/info

REPO := $(CURDIR)/Flute

# ---- Bluespec search path (mirrors Flute builds/Resources/Include_Common.mk)
# JtagTap, Jtag_IFC and ClockHacks live in $(CURDIR)/src (copied from
# Flute/src_SSITH_P2 and stripped of AXI/TLM dependencies).
CORE_DIRS := $(REPO)/src_Core/CPU:$(REPO)/src_Core/ISA:$(REPO)/src_Core/RegFiles:$(REPO)/src_Core/Core:$(REPO)/src_Core/Cache_Config:$(REPO)/src_Core/Near_Mem_VM_WT_L1:$(REPO)/src_Core/PLIC:$(REPO)/src_Core/Near_Mem_IO:$(REPO)/src_Core/Debug_Module:$(REPO)/src_Core/BSV_Additional_Libs
TB_DIRS   := $(REPO)/src_Testbench/SoC:$(REPO)/src_Testbench/Fabrics/AXI4
BSC_PATH  := +:$(CURDIR)/src:$(CORE_DIRS):$(TB_DIRS)

# RV32IMAC, M+U privilege, WT_L1 caches, 64-bit fabric (matches Flute example builds)
# INCLUDE_GDB_CONTROL + JTAG_TAP enable the RISC-V debug module and
# expose it on the ULX3S FTDI bit-banged JTAG pins so OpenOCD can
# load code into SDRAM without the slow UART bootloader.
# Build identifier baked into the SoC Info block (SOC_BUILD_DATE register).
BUILD_DATE := $(shell date +%Y%m%d)

DEFINES := -D RV32 -D ISA_I -D ISA_M -D ISA_A -D ISA_C \
           -D ISA_B -D ISA_ZKN -D ISA_XBOX \
           -D SOC_BUILD_DATE=$(BUILD_DATE) \
           -D ISA_PRIV_M -D ISA_PRIV_U -D ISA_PRIV_S -D SV32 -D SV32_ITLB \
           -D SHIFT_BARREL -D MULT_SYNTH \
           -D Near_Mem_Caches -D FABRIC64 \
           -D INCLUDE_ACCEL0 \
           -D INCLUDE_GDB_CONTROL -D JTAG_TAP

# SYS_PLL=1: 32.142857 MHz system clock from the ECP5 PLL (src/Top.v).
# Changing it needs a clean bsc build (rm -rf build/bsc build/verilog/mkULX3S_Top.v):
# bsc -u does not see -D changes.  Bench: EXPECT_HZ=32142857 scripts/hw_test_suite.py.
SYS_PLL ?= 0
ifeq ($(SYS_PLL),1)
DEFINES     += -D SYS_CLK_HZ=32142857
YOSYS_DEFS  := -DSYS_PLL
else
YOSYS_DEFS  :=
endif

# Sim builds omit the JTAG TAP (the Bluesim top is the BSV module
# itself); the UART DMI bridge provides debug access in simulation too.
# subst (not filter-out): "JTAG_TAP" alone would match nothing, "-D"
# alone would strip every define's prefix.
# BRAM_HAZARD_ASSERT enables the sim-only BRAM access-discipline checks in
# MMU_Cache.bsv (port A write-only / port B read-only / no cross-port
# same-address).  Sim-only: synthesis builds use $(DEFINES), not this.
SIM_DEFINES := $(subst -D JTAG_TAP,,$(DEFINES)) -D BRAM_HAZARD_ASSERT

BSC_FLAGS := -keep-fires -aggressive-conditions -no-warn-action-shadowing -show-schedule \
             -no-show-timestamps -suppress-warnings G0020 \
             +RTS -K128M -RTS

BSV_TOP := mkULX3S_Top
TOP     := ulx3s_top

VERILOG       := $(VDIR)/$(BSV_TOP).v
SYNTH_VERILOG := $(BUILD)/verilog_all.v
JSON          := $(BUILD)/$(TOP).json
CONFIG        := $(BUILD)/$(TOP).config
BITSTREAM     := $(BUILD)/$(TOP).bit
LPF           := constraints/ulx3s_85f.lpf

# ---- Boot ROM
ROM_BSVI := $(REPO)/src_Testbench/SoC/fn_read_ROM_RV32.bsvi

# ================================================================

.PHONY: all compile bootrom synth bitstream sw program run clean dbg-% sim-boot sim-repl sim-dmi-tb sim-gate

all: bitstream sw

# ---- Boot loader -> Boot_ROM include file -------------------------------

bootrom: $(ROM_BSVI)

$(BUILD)/boot_loader.elf: boot/reset.S boot/boot_loader.c
	mkdir -p $(BUILD)
	$(RISCV_PREFIX)gcc -march=rv32imac_zicsr_zifencei -mabi=ilp32 -Os -ffreestanding \
	    -nostdlib -nostartfiles -Wl,-Ttext=0x1000 -Wl,--build-id=none \
	    boot/reset.S boot/boot_loader.c -o $@

$(BUILD)/boot_loader.bin: $(BUILD)/boot_loader.elf
	$(RISCV_PREFIX)objcopy -O binary $< $@

$(BUILD)/boot_loader.memhex: $(BUILD)/boot_loader.bin scripts/bin2rom.py
	python3 scripts/bin2rom.py $< $@

$(ROM_BSVI): $(BUILD)/boot_loader.memhex $(REPO)/src_Testbench/SoC/Boot_ROM_Generator/Gen_BSV_fn_read_ROM.py
	python3 $(REPO)/src_Testbench/SoC/Boot_ROM_Generator/Gen_BSV_fn_read_ROM.py $< $@

# ---- BSV -> Verilog -----------------------------------------------------

compile: $(VERILOG)

$(VERILOG): $(ROM_BSVI) $(wildcard src/*.bsv) $(wildcard $(REPO)/src_Core/*/*.bsv) $(wildcard $(REPO)/src_Testbench/*/*.bsv)
	mkdir -p $(BDIR) $(VDIR) $(IDIR)
	$(BSC) -u -verilog -g $(BSV_TOP) $(BSC_FLAGS) $(DEFINES) \
	    -p $(BSC_PATH) -bdir $(BDIR) -vdir $(VDIR) -info-dir $(IDIR) \
	    src/ULX3S_Top.bsv > $(BUILD)/elaboration.log 2>&1

# ---- riscv-formal build (RVFI-instrumented mkCPU, own tree) ---------------
# `make formal-verilog` compiles mkCPU (not the SoC) with -D RVFI into
# build/formal/, where the tiny cache/BTB geometry and the RVFI record are
# enabled.  Consumed by formal/run.sh (riscv-formal checks).  Never shares
# build/bsc with the production build.
FBDIR := $(BUILD)/formal/bsc
FVDIR := $(BUILD)/formal/verilog
FIDIR := $(BUILD)/formal/info
FORMAL_VERILOG := $(BUILD)/formal/verilog_cpu.v

.PHONY: formal-verilog
formal-verilog: $(FORMAL_VERILOG)

$(FORMAL_VERILOG): $(wildcard $(REPO)/src_Core/*/*.bsv)
	mkdir -p $(FBDIR) $(FVDIR) $(FIDIR)
	$(BSC) -u -verilog -g mkCPU $(BSC_FLAGS) $(DEFINES) -D RVFI \
	    -p $(BSC_PATH) -bdir $(FBDIR) -vdir $(FVDIR) -info-dir $(FIDIR) \
	    $(REPO)/src_Core/CPU/CPU.bsv > $(BUILD)/formal/elaboration.log 2>&1
	cat $(FVDIR)/*.v > $@

# ---- Elaboration-time SoC manifest (memory map / irqs / board) -----------
# The Bluesoc design emits MEMMAP/MEMMAPIRQ/BOARD lines via messageM during
# elaboration (captured above).  Extract them into a machine-readable JSON
# that software builds consume (TempleOS gen_board_hc.py, and any future C
# headers / linker scripts / DTS).  This is the map of the ACTUAL elaborated
# hardware -- same DEFINES, same config as the bitstream.

MANIFEST := $(BUILD)/soc-memory-map.json

$(MANIFEST): $(BUILD)/elaboration.log scripts/soc_manifest.py
	python3 scripts/soc_manifest.py $(BUILD)/elaboration.log $@

manifest: $(MANIFEST)

.PHONY: manifest

# ---- Verilog -> bitstream ------------------------------------------------

# Strip simulation-only constructs Yosys rejects: drop synopsys
# translate_off regions (as in bluespec-ulx3s) and neutralize
# $fflush/$finish calls left dangling by -check-assert removal.
$(SYNTH_VERILOG): $(VERILOG)
	mkdir -p $(BUILD)
	for f in $(VDIR)/*.v; do \
	    perl -0pe 's/\$$display[ \t]*\((?:"[^"]*"|[^";])*;/;/gs;  \
	               s/\$$write[ \t]*\((?:"[^"]*"|[^";])*;/;/gs;    \
	               s/\$$fwrite[ \t]*\((?:"[^"]*"|[^";])*;/;/gs;   \
	               s/\$$fdisplay[ \t]*\((?:"[^"]*"|[^";])*;/;/gs; \
	               s/\$$fflush[^;]*;/;/gs;                          \
	               s/\$$finish[^;]*;/;/gs;                          \
	               s/#0;/;/g' $$f; \
	done > $@

$(JSON): $(SYNTH_VERILOG) src/Top.v src/ASSIGN1.v
	$(YOSYS) -p 'read_verilog -DINCLUDE_GDB_CONTROL $(YOSYS_DEFS) $(BSC_VERILOG_FILES) src/ASSIGN1.v $(SYNTH_VERILOG) src/Top.v; synth_ecp5 -top $(TOP) -json $@'

synth: $(JSON)

$(CONFIG): $(JSON) $(LPF)
	$(NEXTPNR) --$(DEVICE) --package CABGA381 --json $(JSON) --lpf $(LPF) --textcfg $@ --seed $(SEED)

$(BITSTREAM): $(CONFIG)
	$(ECPPACK) --compress $< $@

bitstream: $(BITSTREAM)

# ---- Software -------------------------------------------------------------

sw:
	$(MAKE) -C sw RISCV_PREFIX=$(RISCV_PREFIX)

# ---- Hardware -------------------------------------------------------------

program: $(BITSTREAM)
	openFPGALoader -b ulx3s -m $(BITSTREAM)

run: $(BITSTREAM) sw/hello.bin
	openFPGALoader -b ulx3s -m $(BITSTREAM)
	python3 scripts/loader.py sw/hello.bin

# ---- TempleOS HolyC monitor -------------------------------------------------

templeos:
	$(MAKE) -C templeos build/monitor/monitor.bin

templeos-run: $(BITSTREAM) templeos
	openFPGALoader -b ulx3s -m $(BITSTREAM)
	python3 scripts/loader.py templeos/build/monitor/monitor.bin -t 0

templeos-smoke: $(BITSTREAM) templeos
	openFPGALoader -b ulx3s -m $(BITSTREAM)
	python3 scripts/monitor.py

# ---- Full HolyC REPL ---------------------------------------------------------

templeos-repl:
	$(MAKE) -C templeos repl

templeos-repl-run: $(BITSTREAM) templeos-repl
	openFPGALoader -b ulx3s -m $(BITSTREAM)
	python3 scripts/loader.py templeos/build/ulx3s_repl.blob.bin -t 0

# ---- On-chip debugging via the UART DMI bridge -------------------------------

# The J1-header JTAG TAP was replaced by Uart_DMI_Bridge (see README);
# the old openocd/ configs only target the ECP5 config TAP and do not work.
DMI_PORT ?= /dev/cu.usbserial-120001

dbg-%:
	python3 scripts/dmi.py -p $(DMI_PORT) $*

# ---- Bluesim full-system tests ------------------------------------------------
#
# sim-boot: quick regression -- boot ROM loads sw/hello.bin over the UART
#           into the behavioral W9825G6KH SDRAM model (TB_PROBES on, so
#           the Sdram_Controller per-beat SIM PROBEs are logged).
# sim-repl: boots the 2.9 MB TempleOS HolyC REPL blob (preloaded into the
#           model over BDPI; the boot ROM jumps straight to it on a
#           len==0 header), sends '1+1;', then catches the hang through
#           the in-sim UART DMI bridge (halt + dpc/x0..x31/code dump).
#           Keeps TB_PROBES off so the REPL boot doesn't log millions of
#           SDRAM beats.

# fn_hello_bytes.bsvi: image bytes for SoC_Boot_Tb's UART host.  Regenerated
# from sw/hello.bin so the tb's loader header can never desync from the
# image (stale length bytes = silent loader failure, see HANDOFF Track D0).
HELLO_BSVI := test/fn_hello_bytes.bsvi

$(HELLO_BSVI): sw/hello.bin scripts/bin2hello_bsvi.py
	python3 scripts/bin2hello_bsvi.py

sim-boot: $(ROM_BSVI) $(HELLO_BSVI)
	mkdir -p $(BUILD)/bsc-sim-boot $(BUILD)/sim-boot
	$(BSC) -u -sim -g mkSoC_Boot_Tb $(BSC_FLAGS) $(SIM_DEFINES) -D TB_PROBES -D SDCAP_PROBES \
	    -p $(BSC_PATH):test -bdir $(BUILD)/bsc-sim-boot -simdir $(BUILD)/sim-boot \
	    test/SoC_Boot_Tb.bsv
	$(BSC) -sim -e mkSoC_Boot_Tb -bdir $(BUILD)/bsc-sim-boot \
	    -simdir $(BUILD)/sim-boot -o $(BUILD)/soc_boot_tb
	PATH="$(abspath $(dir $(BSC))):$$PATH" $(BUILD)/soc_boot_tb

# sim-gate: THE checked Bluesim gate.  Runs both sims and greps for
# ASSERT FAIL (Bluesim $finish AND $fatal both exit 0 — verified on this
# bsc build, see HANDOFF Track A1), so make's exit code alone cannot be
# trusted.  Fails on any make error, any ASSERT FAIL, or a missing image.
.PHONY: sim-gate
sim-gate:
	@echo "=== sim-gate: sim-boot ==="
	$(MAKE) sim-boot > $(BUILD)/timing-exp/sim-gate-boot.log 2>&1 || { echo "sim-gate: sim-boot FAILED (make exit)"; exit 1; }
	@echo "=== sim-gate: sim-repl ==="
	$(MAKE) sim-repl > $(BUILD)/timing-exp/sim-gate-repl.log 2>&1 || { echo "sim-gate: sim-repl FAILED (make exit)"; exit 1; }
	@n1=$$(LC_ALL=C grep -c "ASSERT FAIL" $(BUILD)/timing-exp/sim-gate-boot.log || true); \
	n2=$$(LC_ALL=C grep -c "ASSERT FAIL" $(BUILD)/timing-exp/sim-gate-repl.log || true); \
	e1=$$(LC_ALL=C grep -c "ERROR" $(BUILD)/timing-exp/sim-gate-boot.log || true); \
	e2=$$(LC_ALL=C grep -c "ERROR" $(BUILD)/timing-exp/sim-gate-repl.log || true); \
	t1=$$(LC_ALL=C grep -c "TIMEOUT after" $(BUILD)/timing-exp/sim-gate-boot.log || true); \
	echo "sim-gate: ASSERT FAIL counts boot=$$n1 repl=$$n2; ERROR counts boot=$$e1 repl=$$e2; boot TIMEOUT markers=$$t1"; \
	if [ "$$n1" != "0" ] || [ "$$n2" != "0" ]; then echo "sim-gate: FAIL (ASSERT)"; exit 1; fi; \
	if [ "$$e1" != "0" ] || [ "$$e2" != "0" ]; then echo "sim-gate: FAIL (ERROR)"; exit 1; fi; \
	if [ "$$t1" = "0" ]; then echo "sim-gate: FAIL (boot did not reach TIMEOUT end)"; exit 1; fi; \
	echo "sim-gate: PASS"

sim-repl: $(ROM_BSVI)
	mkdir -p $(BUILD)/bsc-sim-repl $(BUILD)/sim-repl
	$(BSC) -u -sim -g mkRepl_Boot_Tb $(BSC_FLAGS) $(SIM_DEFINES) -D UART_PROBES -D MDL_PROBES -D SDCAP_PROBES \
	    -p $(BSC_PATH):test -bdir $(BUILD)/bsc-sim-repl -simdir $(BUILD)/sim-repl \
	    test/Repl_Boot_Tb.bsv
	$(BSC) -sim -e mkRepl_Boot_Tb -bdir $(BUILD)/bsc-sim-repl \
	    -simdir $(BUILD)/sim-repl -o $(BUILD)/repl_boot_tb test/sim_preload.c
	PATH="$(abspath $(dir $(BSC))):$$PATH" $(BUILD)/repl_boot_tb

# sim-dmi-tb: unit test for the Uart_DMI_Bridge pass-through path --
# bare 0xDB losslessness (incl. consecutive), partial-magic mismatch
# replay, trailing-0xDB release via the ST_MAGIC idle timeout, and
# magic arming / 'q' disarm.  Runs in seconds; no ROM or SDRAM model.

sim-dmi-tb:
	mkdir -p $(BUILD)/bsc-sim-dmi-tb $(BUILD)/sim-dmi-tb
	$(BSC) -u -sim -g mkUart_DMI_Tb $(BSC_FLAGS) \
	    -p $(BSC_PATH):test -bdir $(BUILD)/bsc-sim-dmi-tb -simdir $(BUILD)/sim-dmi-tb \
	    test/Uart_DMI_Tb.bsv
	$(BSC) -sim -e mkUart_DMI_Tb -bdir $(BUILD)/bsc-sim-dmi-tb \
	    -simdir $(BUILD)/sim-dmi-tb -o $(BUILD)/uart_dmi_tb
	PATH="$(abspath $(dir $(BSC))):$$PATH" $(BUILD)/uart_dmi_tb

clean:
	rm -rf $(BUILD)
	$(MAKE) -C sw clean 2>/dev/null || true
	$(MAKE) -C templeos clean 2>/dev/null || true
