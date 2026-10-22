# RISCOF DUT plugin: Flute RV32 (linux-isa) on the sim/isa_bram Verilator SoC bench.
#
# Each test is compiled with the riscv64-unknown-elf toolchain, then run with
# sim/isa_bram/isa_run.py --sig: the ELF is preloaded into the SDRAM model, the boot ROM
# jumps to 0x80000000, the run ends on the first nonzero tohost write (+ a drain window),
# and begin_signature..end_signature is dumped in Sail --test-signature format.
import os
import re
import shutil
import logging

import riscof.utils as utils
from riscof.pluginTemplate import pluginTemplate

logger = logging.getLogger()

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))


def gcc_march(isa):
    """RVTEST_ISA entry (e.g. RV32IZba, RV32I_Zicsr) -> a -march GCC 14 accepts."""
    m = re.match(r"(rv32|rv64)([a-y]*)(.*)", isa.lower())
    base, single, multi = m.group(1), m.group(2), m.group(3)
    exts = [e for e in re.split(r"_|(?=z)", multi) if e]
    for e in ("zicsr", "zifencei"):        # the arch_test.h trap handler uses CSRs
        if e not in exts:
            exts.append(e)
    return base + single + "".join("_" + e for e in exts)


class flute(pluginTemplate):
    __model__ = "flute"
    __version__ = "linux-isa"

    def __init__(self, *args, **kwargs):
        sclass = super().__init__(*args, **kwargs)
        config = kwargs.get("config")
        if config is None:
            logger.error("Config node for flute missing.")
            raise SystemExit(1)
        self.num_jobs = str(config.get("jobs", 1))
        self.pluginpath = os.path.abspath(config["pluginpath"])
        self.isa_spec = os.path.abspath(config["ispec"])
        self.platform_spec = os.path.abspath(config["pspec"])
        self.bench = os.path.abspath(config.get("bench", os.path.join(ROOT, "sim", "isa_bram")))
        self.verilog_all = os.path.abspath(config.get(
            "verilog_all", os.path.join(ROOT, "build", "timing-exp", "verilog_all.v.v8")))
        self.build_dir = config.get("build_dir", "obj_dir_riscof")
        self.deadline = str(config.get("deadline", 50000000))
        self.target_run = config.get("target_run", "1") != "0"
        return sclass

    def initialise(self, suite, work_dir, archtest_env):
        self.work_dir = work_dir
        self.suite_dir = suite
        self.compile_cmd = ("riscv64-unknown-elf-gcc -march={0} -mabi=ilp32 -static -mcmodel=medany"
                            " -fvisibility=hidden -nostdlib -nostartfiles"
                            " -T " + self.pluginpath + "/env/link.ld"
                            " -I " + self.pluginpath + "/env/ -I " + archtest_env)

    def build(self, isa_yaml, platform_yaml):
        for tool in ("riscv64-unknown-elf-gcc", "riscv64-unknown-elf-objdump", "verilator", "make"):
            if shutil.which(tool) is None:
                logger.error(tool + ": executable not found")
                raise SystemExit(1)
        sim = os.path.join(self.bench, self.build_dir, "Vsv_tb_top")
        if self.target_run and not os.path.exists(sim):
            logger.info("building " + sim + " from " + self.verilog_all)
            log = os.path.join(self.bench, self.build_dir + ".build.log")
            rc = os.system("cd {0} && BUILD_DIR={1} VERILOG_ALL={2} JOBS={3} ./build_only.sh > {4} 2>&1".format(
                self.bench, self.build_dir, self.verilog_all, self.num_jobs, log))
            if rc != 0 or not os.path.exists(sim):
                logger.error("Verilator build failed, see " + log)
                raise SystemExit(1)

    def runTests(self, testList):
        mk = os.path.join(self.work_dir, "Makefile." + self.name[:-1])
        if os.path.exists(mk):
            os.remove(mk)
        make = utils.makeUtil(makefilePath=mk)
        make.makeCommand = "make -k -j" + self.num_jobs
        for testname in testList:
            te = testList[testname]
            test = te["test_path"]
            wd = te["work_dir"]
            elf = "my.elf"
            sig = os.path.join(wd, self.name[:-1] + ".signature")
            cmd = "@cd " + wd + ";"
            cmd += self.compile_cmd.format(gcc_march(te["isa"])) + " " + test + " -o " + elf
            cmd += " -D" + " -D".join(te["macros"]) + ";"
            cmd += "riscv64-unknown-elf-objdump -D " + elf + " > dut.disass;"
            if self.target_run:
                # STRICT_BRAM=warn: as the J1 gates (a raw sim without it corrupts benign BTB
                # cross-port reads; isa_run.py drops its per-event census lines and caps the
                # sim log at 20 MB); TMPDIR: isa_run.py's bin/hex/log land in the test dir.
                cmd += ("STRICT_BRAM=warn TMPDIR={wd} BUILD_DIR={bd} python3 {bench}/isa_run.py"
                        " --jobs 1 --deadline {dl} --sig {sig} {wd}/{elf} 2>&1 | head -c 20000000 > dut.log;").format(
                    wd=wd, bd=self.build_dir, bench=self.bench, dl=self.deadline, sig=sig, elf=elf)
            make.add_target(cmd)
        make.execute_all(self.work_dir, timeout=86400)   # riscof default: 300 s for the whole suite
        if not self.target_run:
            raise SystemExit(0)
