#!/usr/bin/env python3
"""Run riscv-tests ELFs on the strict-BRAM SoC sim (sim/isa_bram): SDRAM preload + jump,
pass/fail from the first nonzero tohost write.
usage: isa_run.py [--build] [--jobs N] [--deadline CYCLES] [--sig FILE] ELF...   (env: VERILOG_ALL, BUILD_DIR)
--sig FILE (one ELF): dump begin_signature..end_signature to FILE in Sail --test-signature
format (riscv-arch-test / RISCOF, see compliance/); coverage goes to /dev/null."""
import argparse, os, re, subprocess, sys, tempfile, concurrent.futures as cf
HERE = os.path.dirname(os.path.abspath(__file__))
LOG_CAP = int(os.environ.get("ISA_LOG_CAP", 20000000))
OBJCOPY = "riscv64-unknown-elf-objcopy"; NM = "riscv64-unknown-elf-nm"

def model_idx(addr):
    b = addr - 0x80000000
    # Sdram_Controller: line l = b >> 6 in bank l[1:0], row l[18:6], col {l[5:2], halfword}
    l, hw = b >> 6, (b >> 1) & 31
    return (l & 3) << 22 | ((l >> 6) & 0x1FFF) << 9 | ((l >> 2) & 15) << 5 | hw

def prep(elf, work):
    base = os.path.join(work, os.path.basename(elf))
    subprocess.run([OBJCOPY, "-O", "binary", elf, base + ".bin"], check=True)
    img = open(base + ".bin", "rb").read()
    if len(img) % 2: img += b"\0"
    with open(base + ".hex", "w") as f:
        last = None
        for i in range(0, len(img), 2):
            hwv = img[i] | img[i + 1] << 8
            if hwv == 0: continue
            idx = model_idx(0x80000000 + i)
            if idx != last: f.write(f"@{idx:x}\n")
            f.write(f"{hwv:04x}\n"); last = idx + 1
    syms = dict((l.split()[2], int(l.split()[0], 16)) for l in subprocess.run([NM, elf], capture_output=True, text=True).stdout.splitlines() if len(l.split()) == 3)
    return base, model_idx(syms["tohost"]), syms

def run_one(elf, work, sim, deadline, sig=None):
    base, th, syms = prep(elf, work)
    env = dict(os.environ, TB_ISA="1", TB_HELLO_DEADLINE=str(deadline))
    extra = []
    if sig:
        env.update(TB_SIG=os.path.abspath(sig), TB_SIG_BEGIN=f"{syms['begin_signature']:x}", TB_SIG_END=f"{syms['end_signature']:x}")
        extra = ["+verilator+coverage+file+/dev/null"]
    # Stream the sim output: per-event STRICT_BRAM census lines are counted, not kept, and the
    # kept log is capped at LOG_CAP bytes (a hung test must not fill the disk).
    p = subprocess.Popen([sim, base + ".bin", f"+PRELOAD={base}.hex", f"+TOHOST={th:x}", "+SB_OFF"] + extra,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace", env=env, cwd=HERE)
    keep, size, census, dropped = [], 0, 0, 0
    for line in p.stdout:
        if "STRICT_BRAM" in line and "summary" not in line and not line.startswith("[tb]"):
            census += 1; continue
        if size + len(line) > LOG_CAP: dropped += 1; continue
        keep.append(line); size += len(line)
    p.wait()
    if census: keep.append(f"[isa_run] {census} STRICT_BRAM census lines dropped\n")
    if dropped: keep.append(f"[isa_run] {dropped} lines dropped past the {LOG_CAP}-byte log cap\n")
    out = "".join(keep)
    open(base + ".log", "w").write(out)
    m = re.search(r"ISA PASS at cycle (\d+)", out)
    if m: return (os.path.basename(elf), "PASS", m.group(1))
    m = re.search(r"ISA FAIL: tohost (\S+) \(test (\d+)\)", out)
    if m: return (os.path.basename(elf), f"FAIL test {m.group(2)}", "")
    m = re.search(r"FAIL at cycle (\d+): ([^\n]*)", out)
    return (os.path.basename(elf), "FAIL " + (m.group(2) if m else "?"), base + ".log")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", action="store_true"); ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--deadline", type=int, default=20000000); ap.add_argument("--sig"); ap.add_argument("elfs", nargs="+")
    a = ap.parse_args()
    if a.sig and len(a.elfs) != 1: sys.exit("--sig takes exactly one ELF")
    bd = os.environ.get("BUILD_DIR", "obj_dir_isa")
    sim = os.path.join(HERE, bd, "Vsv_tb_top")
    if a.build or not os.path.exists(sim):
        # build only: run.sh builds then runs the default image; a dummy run is cut short
        r = subprocess.run(["bash", "-c", f"cd {HERE} && BUILD_DIR={bd} TB_ISA=1 TB_HELLO_DEADLINE=1 ./run.sh --strict=warn {a.elfs[0]} > {bd}.build.log 2>&1; grep -c 'VERILATE/BUILD FAILED' {bd}.build.log"], capture_output=True, text=True)
        if not os.path.exists(sim): sys.exit(f"build failed: see {HERE}/{bd}.build.log")
    work = tempfile.mkdtemp(prefix="isa_")
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        res = list(ex.map(lambda e: run_one(e, work, sim, a.deadline, a.sig), a.elfs))
    npass = 0
    for n, v, x in sorted(res):
        print(f"{n:28s} {v} {x}"); npass += v == "PASS"
    print(f"{npass}/{len(res)} PASS (logs in {work})")

if __name__ == "__main__":
    main()
