#!/usr/bin/env python3
"""Attach to a running REPL (already booted via sba_load --go), watch
the console for the prompt, send a command to trigger the hang, then
leave the hart running so dmi.py can catch it."""

import argparse
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from dmi import DMI


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-p", "--port", default="/dev/cu.usbserial-120001")
    ap.add_argument("-b", "--baud", type=int, default=625000)
    ap.add_argument("-c", "--cmd", default="1+1;")
    ap.add_argument("--prompt", default="> ")
    ap.add_argument("--wait", type=float, default=180.0)
    args = ap.parse_args()

    dmi = DMI(args.port, args.baud)
    try:
        # Drain whatever the REPL has printed so far (banner etc.).
        out = dmi.read_console(args.wait)
        sys.stdout.write(out.decode("utf-8", "replace"))
        sys.stdout.flush()
        if args.prompt.encode() not in out:
            print("\n[repl_hang] prompt not seen yet; sending anyway",
                  file=sys.stderr)
        dmi.write_console(args.cmd.encode() + b"\r\n")
        print(f"\n[repl_hang] sent {args.cmd!r}; waiting 3s for output",
              file=sys.stderr)
        time.sleep(3)
        out = dmi.read_console(1.0)
        sys.stdout.write(out.decode("utf-8", "replace"))
        sys.stdout.flush()
        print("\n[repl_hang] done - hart left running (hung). Now run:\n"
              "  python3 scripts/dmi.py -p %s --stay pc" % args.port,
              file=sys.stderr)
    finally:
        dmi.close()


if __name__ == "__main__":
    main()
