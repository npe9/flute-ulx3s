# riscv-tests debug suite target for the ULX3S Flute SoC (lx45d and later), over the US1 cable's
# JTAG through JTAGG (src/JtaggDtm.bsv) and scripts/ft231x_jtag.py's remote_bitbang server.
# Run with test/debug/run.sh.
import targets


class FluteUlx3sHart(targets.Hart):
    xlen = 32
    misa = 0x4014112f                  # RV32IMAFDC + B, S, U (what the SoC reports)
    ram = 0x80100000                   # SDRAM, above the first MB (loaded programs live there)
    ram_size = 1024 * 1024
    bad_address = 0x70000000           # unmapped: the fabric answers DECERR
    instruction_hardware_breakpoint_count = 0   # no trigger module (tdata1 reads "no trigger")
    honors_tdata1_dmode = False
    reset_vectors = [0x1000]           # boot ROM
    link_script_path = "FluteUlx3s.lds"


class FluteUlx3s(targets.Target):
    harts = [FluteUlx3sHart()]
    openocd_config_path = "FluteUlx3s.cfg"
    timeout_sec = 30                   # bitbang JTAG over a full-speed FT231X is slow
    server_timeout_sec = 120
    supports_clint_mtime = True
    clint_addr = 0x02000000
    support_hasel = False
    test_semihosting = False
    support_manual_hwbp = False
    support_memory_sampling = False
    support_mcontrol = False
    support_mcontrol6 = False
    support_icount = False
    support_itrigger = False
    support_etrigger = False
    invalid_memory_returns_zero = False
    minimum_pmp_granularity = 4096     # G = 10
    # Not applicable here (each with its reason; anything else must pass):
    skip_tests = [
        # no trigger module: tselect / tdata1 read "no trigger" (Sdtrig not implemented)
        "TriggerExecuteInstant", "TriggerLoadAddressInstant", "TriggerStoreAddressInstant",
        "ProgramHwWatchpoint",
        # parses riscv-openocd's newer "[target] Re-reading memory" message; OpenOCD 0.12 differs
        "RepeatReadTest",
        # semihosting file I/O needs OpenOCD's semihosting fileio set up for the host
        "SemihostingFileio",
    ]
