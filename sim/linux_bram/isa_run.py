#!/usr/bin/env python3
"""Run riscv-tests ELFs on the strict-BRAM SoC sim (sim/isa_bram): SDRAM preload + jump,
pass/fail from the first nonzero tohost write.
usage: isa_run.py [--build] [--jobs N] [--deadline CYCLES] ELF...   (env: VERILOG_ALL, BUILD_DIR)"""
import argparse, os, re, subprocess, sys, tempfile, concurrent.futures as cf
HERE = os.path.dirname(os.path.abspath(__file__))
OBJCOPY = "riscv64-unknown-elf-objcopy"; NM = "riscv64-unknown-elf-nm"

def model_idx(addr):
    b = addr - 0x80000000
    r, hw = b >> 5, (b >> 1) & 15
    return ((r >> 5) & 3) << 22 | ((r >> 7) & 0x1FFF) << 9 | (r & 0x1F) << 4 | hw

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
    return base, model_idx(syms["tohost"])

def run_one(elf, work, sim, deadline):
    base, th = prep(elf, work)
    env = dict(os.environ, TB_ISA="1", TB_HELLO_DEADLINE=str(deadline))
    p = subprocess.run([sim, base + ".bin", f"+PRELOAD={base}.hex", f"+TOHOST={th:x}", "+SB_OFF"], capture_output=True, text=True, env=env, cwd=HERE)
    out = p.stdout + p.stderr
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
    ap.add_argument("--deadline", type=int, default=20000000); ap.add_argument("elfs", nargs="+")
    a = ap.parse_args()
    bd = os.environ.get("BUILD_DIR", "obj_dir_isa")
    sim = os.path.join(HERE, bd, "Vsv_tb_top")
    if a.build or not os.path.exists(sim):
        # build only: run.sh builds then runs the default image; a dummy run is cut short
        r = subprocess.run(["bash", "-c", f"cd {HERE} && BUILD_DIR={bd} TB_ISA=1 TB_HELLO_DEADLINE=1 ./run.sh --strict=warn {a.elfs[0]} > {bd}.build.log 2>&1; grep -c 'VERILATE/BUILD FAILED' {bd}.build.log"], capture_output=True, text=True)
        if not os.path.exists(sim): sys.exit(f"build failed: see {HERE}/{bd}.build.log")
    work = tempfile.mkdtemp(prefix="isa_")
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        res = list(ex.map(lambda e: run_one(e, work, sim, a.deadline), a.elfs))
    npass = 0
    for n, v, x in sorted(res):
        print(f"{n:28s} {v} {x}"); npass += v == "PASS"
    print(f"{npass}/{len(res)} PASS (logs in {work})")

if __name__ == "__main__":
    main()
