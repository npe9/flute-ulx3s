#!/usr/bin/env python3
"""Drive the virtual board (`make sim-board`) through its pty like a user at a terminal.

  ci/board_smoke.py [--tty build/sim-tty] [--expect-prompt '\\n> '] [--send '1+1;'] [--expect '=2']
                    [--timeout SECONDS]

Waits for the prompt, types the command (CR-terminated), waits for the expected text, prints
the console transcript, exits 0 on success.
"""
import argparse, os, select, sys, time, termios, tty

ap = argparse.ArgumentParser()
ap.add_argument("--tty", default="build/sim-tty")
ap.add_argument("--expect-prompt", default="\n> ")
ap.add_argument("--send", default="1+1;")
ap.add_argument("--expect", default="=2")
ap.add_argument("--timeout", type=float, default=3600)
a = ap.parse_args()

deadline = time.time() + a.timeout
while not os.path.exists(a.tty):
    if time.time() > deadline: sys.exit(f"no {a.tty}")
    time.sleep(1)
fd = os.open(a.tty, os.O_RDWR | os.O_NOCTTY)
tty.setraw(fd)
buf = b""

def wait_for(s):
    global buf
    start = len(buf)
    while s.encode() not in buf[start if s != a.expect_prompt else 0:]:
        if time.time() > deadline:
            sys.stdout.write(buf.decode(errors="replace")); sys.exit(f"\nTIMEOUT waiting for {s!r}")
        r, _, _ = select.select([fd], [], [], 5)
        if r:
            buf += os.read(fd, 4096)

wait_for(a.expect_prompt)
mark = len(buf)
for ch in (a.send + "\r").encode():
    os.write(fd, bytes([ch])); time.sleep(0.05)   # ~one byte per 10K sim cycles: no overrun
buf_before = buf
wait_for(a.expect)
sys.stdout.write(buf.decode(errors="replace"))
print(f"\nboard_smoke: PASS ({a.send!r} -> {a.expect!r})")
