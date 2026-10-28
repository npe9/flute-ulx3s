# ================================================================
# TestRIG RVFI-DII build of the Flute core (Bluesim).  See testrig/README.md.
#
#   make -C testrig            : build build/testrig-dii/Flute_RVFI_DII (listens on $RVFI_DII_PORT, default 5001)
#   make -C testrig netlist-check : production netlist hash with and without this branch's RVFI_DII hooks
#
# Same ISA / core defines as the production build (../Makefile DEFINES),
# minus JTAG_TAP, plus -D RVFI -D RVFI_DII.  Production builds never see
# RVFI_DII, and everything added for TestRIG is behind that flag.
# ================================================================

ROOT    := $(abspath ..)
BSC     ?= $(shell $(ROOT)/scripts/bsc_bin.sh)
REPO    := $(ROOT)/Flute
OUT     ?= $(ROOT)/build/testrig-dii
JOBS    ?= 4

CORE_DIRS := $(REPO)/src_Core/CPU:$(REPO)/src_Core/ISA:$(REPO)/src_Core/RegFiles:$(REPO)/src_Core/Core:$(REPO)/src_Core/Cache_Config:$(REPO)/src_Core/Near_Mem_VM_WT_L1:$(REPO)/src_Core/PLIC:$(REPO)/src_Core/Near_Mem_IO:$(REPO)/src_Core/Debug_Module:$(REPO)/src_Core/BSV_Additional_Libs
TB_DIRS   := $(REPO)/src_Testbench/SoC:$(REPO)/src_Testbench/Fabrics/AXI4:$(REPO)/src_Testbench/RVFI_DII
BSC_PATH  := +:$(ROOT)/src:$(CORE_DIRS):$(TB_DIRS)

DEFINES := -D RV32 -D ISA_I -D ISA_M -D ISA_A -D ISA_C \
           -D ISA_B -D ISA_ZKN -D ISA_ZKR -D ISA_XBOX \
           -D SOC_BUILD_DATE=0 \
           -D ISA_PRIV_M -D ISA_PRIV_U -D ISA_PRIV_S -D SV32 -D SV32_ITLB \
           -D SHIFT_BARREL -D MULT_SYNTH \
           -D Near_Mem_Caches -D FABRIC64 \
           -D INCLUDE_ACCEL0 \
           -D INCLUDE_GDB_CONTROL \
           -D RVFI -D RVFI_DII $(EXTRA_DEFINES)

BSC_FLAGS := -keep-fires -aggressive-conditions -no-warn-action-shadowing \
             -no-show-timestamps -suppress-warnings G0020:G0010:G0021 \
             +RTS -K128M -RTS

DII_C := $(REPO)/src_Testbench/RVFI_DII/socket_packet_utils.c $(REPO)/src_Testbench/RVFI_DII/dii_mem.c

EXE := $(OUT)/Flute_RVFI_DII

.PHONY: all clean netlist-check ram8m
all: $(EXE)

# Variant with Sail's default RVFI-DII platform map (8 MiB RAM at 0x8000_0000,
# everything else vacant); run with RAM8M=1 testrig/run_testrig.sh ...
ram8m:
	$(MAKE) OUT=$(ROOT)/build/testrig-dii-ram8m EXTRA_DEFINES="-D RVFI_DII_RAM_8M"

$(EXE): $(wildcard $(REPO)/src_Core/*/*.bsv) $(wildcard $(REPO)/src_Testbench/*/*.bsv) $(DII_C)
	mkdir -p $(OUT)/bsc $(OUT)/sim $(OUT)/info
	$(BSC) -u -sim -g mkFlute_RVFI_DII $(BSC_FLAGS) $(DEFINES) \
	    -p $(BSC_PATH) -bdir $(OUT)/bsc -simdir $(OUT)/sim -info-dir $(OUT)/info \
	    $(REPO)/src_Testbench/RVFI_DII/Flute_RVFI_DII.bsv > $(OUT)/compile.log 2>&1 \
	    || (tail -40 $(OUT)/compile.log; false)
	mkdir -p $(OUT)/csrc && cp $(DII_C) $(OUT)/csrc/
	$(BSC) -sim -parallel-sim-link $(JOBS) -e mkFlute_RVFI_DII -o $(EXE) \
	    -bdir $(OUT)/bsc -simdir $(OUT)/sim -info-dir $(OUT)/info -p $(BSC_PATH) \
	    $(addprefix $(OUT)/csrc/,$(notdir $(DII_C))) > $(OUT)/link.log 2>&1 \
	    || (tail -40 $(OUT)/link.log; false)
	@echo "built $(EXE)"

# Production-netlist identity check: the V7 production bsc command
# (build/timing-exp/v7-bsc.log, SOC_BUILD_DATE pinned) into build/testrig-<tag>/.
netlist-check:
	./netlist_hash.sh $(TAG)

clean:
	rm -rf $(OUT)
