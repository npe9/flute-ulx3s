#!/usr/bin/env python3
"""Boot a raw firmware image (OpenSBI fw_payload.bin: OpenSBI + Linux + DTB) on the strict-BRAM SoC
sim: SDRAM preload at 0x80000000 + jump (TB_ISA mode), live UART echo, pass when the UART shows
--pass (default: the /init tick line).
--board: the Verilator virtual board instead -- the UART is bridged to a host pty (build/sim-tty),
no pass string, runs until killed; IMAGE "none" preloads nothing (the boot ROM waits for
scripts/loader.py --sim).
usage: linux_run.py [--board] [--pass STR] [--deadline CYCLES] [--progress N] IMAGE.bin   (env: BUILD_DIR)"""
import argparse, os, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from isa_run import model_idx

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image"); ap.add_argument("--pass", dest="pas", default="tick 2")
    ap.add_argument("--deadline", type=int, default=2_000_000_000)
    ap.add_argument("--progress", type=int, default=10_000_000)
    ap.add_argument("--board", action="store_true", help="virtual board: UART on a host pty")
    a = ap.parse_args()
    sim = os.path.join(HERE, os.environ.get("BUILD_DIR", "obj_dir_lx"), "Vsv_tb_top")
    env = dict(os.environ, TB_HELLO_DEADLINE=str(a.deadline), TB_PROGRESS=str(a.progress))
    args = [sim]
    if a.board:
        env.update(TB_PTY="1", TB_PROGRESS="0")
        env.setdefault("SIM_PTY_LINK", os.path.join(HERE, "..", "..", "build", "sim-tty"))
        env["SIM_PTY_LINK"] = os.path.abspath(env["SIM_PTY_LINK"])
    else:
        env.update(TB_ECHO="1", TB_PASS_STR=a.pas)
    if a.board and a.image == "none":
        args += [os.devnull, "+SB_OFF"]
        print(f"[linux_run] virtual board, nothing preloaded, sim {sim}", flush=True)
    else:
        work = tempfile.mkdtemp(prefix="lx_")
        img = open(a.image, "rb").read()
        if len(img) % 2: img += b"\0"
        hexf = os.path.join(work, "image.hex")
        with open(hexf, "w") as f:
            last = None
            for i in range(0, len(img), 2):
                hwv = img[i] | img[i + 1] << 8
                if hwv == 0: continue
                idx = model_idx(0x80000000 + i)
                if idx != last: f.write(f"@{idx:x}\n")
                f.write(f"{hwv:04x}\n"); last = idx + 1
        env["TB_ISA"] = "1"
        args += [os.path.abspath(a.image), f"+PRELOAD={hexf}", "+SB_OFF"]
        print(f"[linux_run] {a.image} ({len(img)} bytes), sim {sim}, work {work}", flush=True)
    os.chdir(HERE)
    os.execve(sim, args, env)

if __name__ == "__main__":
    main()
