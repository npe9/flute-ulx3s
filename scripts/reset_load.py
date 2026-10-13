#!/usr/bin/env python3
"""Reset the SoC over the UART DMI bridge, load an image, optionally
send a REPL command, and exit.

Why not loader.py: it cannot recover when it misses the boot banner,
and at this nonstandard baud multi-byte writes are unreliable.  This
script:

  1. issues ndmreset through the debug bridge (banner reprints),
  2. streams the image BYTE-WISE with a small pace -- the only pattern
     observed to deliver every byte via the Mac AppleUSBFTDI driver at
     625000 baud (4KB blocking chunks lose exactly one 64-byte USB
     packet per transfer, at a random position),
  3. verifies progress/completion through the bridge itself: boot ROM
     milestone GPIO at 0xC0002000 (0x13 receive / 0x33 received /
     0xff jumped), receive pointer in s4 while GPIO==0x13, and a final
     SDRAM entry/tail check over the system bus,
  4. reloads on any mismatch.

Usage:
    python3 reset_load.py <image> [-p PORT] [-a ADDR] [-c CMD]
                        [--prompt P] [--pace S]

Example (the REPL hang catch):
    python3 scripts/reset_load.py templeos/build/ulx3s_repl.blob.bin -c '1+1;'
    python3 scripts/dmi.py -p /dev/cu.usbserial-120001 pc
"""

import argparse
import os
import select
import struct
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dmi import DMI

BANNER = b"boot loader\r\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image")
    ap.add_argument("-p", "--port", default="/dev/cu.usbserial-120001")
    ap.add_argument("-b", "--baud", type=int, default=625000)
    ap.add_argument("-a", "--addr", default="0x80000000")
    ap.add_argument("-c", "--cmd")
    ap.add_argument("--prompt", default="> ")
    ap.add_argument("--pace", type=float, default=0.00002,
                    help="seconds between stream bytes (default 0.00002)")
    ap.add_argument("--boot-wait", type=float, default=30.0)
    ap.add_argument("--prompt-wait", type=float, default=120.0)
    args = ap.parse_args()

    addr = int(args.addr, 16)
    data = open(args.image, "rb").read()
    exp_entry = [int.from_bytes(data[4 * i:4 * i + 4], "little")
                 for i in range(4)]
    exp_tail = [int.from_bytes(data[len(data) - 16 + 4 * i:len(data) - 16 + 4 * i + 4],
                               "little") for i in range(4)]

    dmi = DMI(args.port, args.baud)
    try:
        stop = threading.Event()

        def reader():
            while not stop.is_set():
                r, _, _ = select.select([dmi.fd], [], [], 0.1)
                if r:
                    try:
                        os.read(dmi.fd, 65536)
                    except OSError:
                        return

        def wait_banner(timeout):
            seen = b""
            deadline = time.monotonic() + timeout
            while BANNER not in seen and time.monotonic() < deadline:
                seen += dmi.read_console(deadline - time.monotonic())
            return BANNER in seen

        def ndmreset():
            for attempt in range(3):
                dmi.arm()
                dmi.wr(0x10, 0x3)
                time.sleep(0.2)
                dmi.wr(0x10, 0x1)
                dmi.disarm()
                if wait_banner(max(args.boot_wait, 10.0)):
                    return True
                print(f"[reset_load] no banner after ndmreset "
                      f"(attempt {attempt + 1})", file=sys.stderr)
                time.sleep(1)
            return False

        def stream(chunk=None):
            th = threading.Thread(target=reader, daemon=True)
            th.start()
            t0 = time.monotonic()
            try:
                payload = data if chunk is None else chunk
                for i, b in enumerate(payload):
                    dmi.write_console(bytes([b]))
                    if args.pace:
                        time.sleep(args.pace)
                    if (i + 1) % (512 * 1024) == 0:
                        print(f"[reset_load] {(i + 1) * 100 // len(payload)}% "
                              f"({time.monotonic() - t0:.0f}s)", file=sys.stderr)
                # The Mac FTDI driver silently holds back any final
                # partial (<64-byte) USB bulk packet; tcdrain does not
                # flush it.  64 CRs after the real data guarantee the
                # packet holding the image tail is complete and
                # transmitted.  Any surplus bytes sit unread in the
                # 16550 FIFO (the boot ROM reads exactly `count`), and
                # the REPL treats CRs as empty lines.
                dmi.write_console(b"\r" * 64)
            finally:
                stop.set()
                th.join(timeout=1)
                stop.clear()
            print(f"[reset_load] streamed {len(payload)} bytes in "
                  f"{time.monotonic() - t0:.0f}s", file=sys.stderr)

        def boot_gpio():
            dmi.arm()
            v = dmi.mem_read32(0xC0002000)
            dmi.disarm()
            return v

        def boot_progress():
            dmi.arm()
            dmi.halt()
            s4 = dmi.read_gpr(20)
            dmi.resume()
            dmi.disarm()
            return s4 - addr

        def image_ok():
            dmi.arm()
            ok_entry = dmi.mem_read(0x80000000, 4) == exp_entry
            ok_tail = dmi.mem_read(0x80000000 + len(data) - 16, 4) == exp_tail
            dmi.disarm()
            return ok_entry and ok_tail

        def first_divergence():
            """Offset of the first word where SDRAM != image (binary
            search; assumes a dropped-byte shift, so content before the
            first mismatch is correct)."""
            dmi.arm()
            n_words = len(data) // 4
            lo, hi = 0, n_words        # invariant: [0,lo) clean, [hi,*) unknown
            while lo < hi:
                mid = (lo + hi) // 2
                got = dmi.mem_read(0x80000000 + 4 * mid, 1)[0]
                exp = int.from_bytes(data[4 * mid:4 * mid + 4], "little")
                if got == exp:
                    lo = mid + 1
                else:
                    hi = mid
            dmi.disarm()
            return lo * 4

        def hold_window():
            """Re-open the boot ROM's repair window: send a minimal
            no-op load (marker + base + 4 bytes) so the upcoming
            divergence search (~20 s of SBA reads) happens while the
            boot ROM is waiting for input, not after it jumped."""
            dmi.write_console(b"\xa5" + struct.pack("<II", addr, 4))
            dmi.write_console(data[:4])

        def load():
            """One full reset+stream+repair cycle.  Returns True when a
            verified image is sitting in SDRAM."""
            if not ndmreset():
                return False
            dmi.write_console(struct.pack("<II", addr, len(data)))
            stream()
            time.sleep(1)
            for round_ in range(8):
                if image_ok():
                    print(f"[reset_load] image verified "
                          f"(round {round_})", file=sys.stderr)
                    return True
                # Keep the boot ROM in its receive window while we search.
                hold_window()
                time.sleep(0.3)
                div = first_divergence()
                if div >= len(data):
                    print("[reset_load] divergence past image end?!", file=sys.stderr)
                    return False
                print(f"[reset_load] repair round {round_}: "
                      f"reload from +{div:#x} ({len(data) - div} bytes)",
                      file=sys.stderr)
                # The boot ROM is in its post-load repair window (it saw
                # no bytes yet; the window is ~30 s).  Send the 0xA5
                # repair marker plus a fresh header for the tail and
                # stream it.  Trailing CRs are discarded as junk by the
                # window.
                dmi.write_console(b"\xa5" + struct.pack("<II", addr + div,
                                                       len(data) - div))
                stream(data[div:])
                time.sleep(1)
            return False

        ok = False
        for attempt in range(4):
            if load():
                ok = True
                break
            print(f"[reset_load] load attempt {attempt + 1} failed",
                  file=sys.stderr)
        if not ok:
            raise TimeoutError("could not load a verified image")

        print(f"[reset_load] load verified; waiting for prompt {args.prompt!r}",
              file=sys.stderr)

        seen = b""
        deadline = time.monotonic() + args.prompt_wait
        while args.prompt.encode() not in seen:
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError(f"prompt {args.prompt!r} never appeared")
            chunk = dmi.read_console(left)
            if chunk:
                seen += chunk
                sys.stdout.write(chunk.decode("utf-8", "replace"))
                sys.stdout.flush()

        if args.cmd is not None:
            dmi.write_console(args.cmd.encode() + b"\r\n")
            print(f"\n[reset_load] sent {args.cmd!r}", file=sys.stderr)
            time.sleep(3)
            sys.stdout.write(dmi.read_console(1.0).decode("utf-8", "replace"))
            sys.stdout.flush()

        print("\n[reset_load] done", file=sys.stderr)
    finally:
        dmi.close()


if __name__ == "__main__":
    main()
