#!/usr/bin/env python3
"""Load a HolyC REPL blob and exercise a scripted REPL session.

Usage:
    python3 repl_test.py <image> -p PORT -b BAUD cmd1 cmd2 ...

Each command is sent followed by \\r\\n.  After the last command the script
keeps reading UART output until IDLE seconds of silence elapse, then exits.
"""

import argparse
import os
import select
import struct
import sys
import termios
import time

BANNER = b"boot loader\r\n"


def open_serial(path, baud):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    baud_const = {
        9600: termios.B9600,
        19200: termios.B19200,
        38400: termios.B38400,
        57600: termios.B57600,
        115200: termios.B115200,
    }.get(baud)
    attrs = termios.tcgetattr(fd)
    if baud_const is not None:
        attrs[4] = attrs[5] = baud_const
    else:
        attrs[4] = attrs[5] = termios.B115200
    attrs[2] |= termios.CLOCAL | termios.CREAD
    attrs[2] &= ~termios.CSIZE
    attrs[2] |= termios.CS8
    attrs[2] &= ~(termios.PARENB | termios.CSTOPB | termios.CRTSCTS)
    attrs[3] &= ~(termios.ICANON | termios.ECHO | termios.ISIG | termios.IEXTEN)
    attrs[0] &= ~(termios.IXON | termios.IXOFF | termios.ICRNL | termios.INLCR | termios.IGNCR)
    attrs[1] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    if baud_const is None:
        import fcntl
        IOSSIOSPEED = 0x80045402
        fcntl.ioctl(fd, IOSSIOSPEED, struct.pack("I", baud))
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def read_avail(fd, timeout):
    r, _, _ = select.select([fd], [], [], timeout)
    if not r:
        return b""
    try:
        return os.read(fd, 65536)
    except BlockingIOError:
        return b""


def write_all(fd, data):
    off = 0
    while off < len(data):
        _, w, _ = select.select([], [fd], [], None)
        if not w:
            continue
        try:
            n = os.write(fd, data[off:])
        except BlockingIOError:
            continue
        if n == 0:
            raise OSError("write returned 0")
        off += n


def drain(fd, timeout):
    """Read everything available for `timeout` seconds of silence."""
    out = b""
    while True:
        chunk = read_avail(fd, timeout)
        if not chunk:
            break
        out += chunk
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("image", help="binary image to load")
    ap.add_argument("commands", nargs="*", help="REPL commands to send")
    ap.add_argument("-p", "--port", default="/dev/cu.usbserial-120001")
    ap.add_argument("-b", "--baud", type=int, default=625000)
    ap.add_argument("-a", "--addr", default="0x80000000")
    ap.add_argument("--boot-wait", type=float, default=6.0)
    ap.add_argument("--idle", type=float, default=8.0,
                    help="silence seconds after last command before exit")
    ap.add_argument("--post-delay", type=float, default=0.3)
    args = ap.parse_args()

    with open(args.image, "rb") as f:
        payload = f.read()
    dst = int(args.addr, 0)

    fd = open_serial(args.port, args.baud)

    sys.stderr.write("loader: waiting for boot banner on %s ...\n" % args.port)
    buf = b""
    deadline = time.time() + 20
    while BANNER not in buf:
        if time.time() > deadline:
            sys.stderr.write("loader: TIMEOUT waiting for banner\n")
            return 1
        buf += read_avail(fd, 0.5)
    sys.stdout.write(buf.decode("latin-1"))
    sys.stdout.flush()

    header = struct.pack("<II", dst, len(payload))
    sys.stderr.write("loader: sending %d bytes to 0x%08x ...\n" % (len(payload), dst))
    t0 = time.time()
    write_all(fd, header + payload)
    sys.stderr.write("loader: sent in %.1fs\n" % (time.time() - t0))
    sys.stderr.flush()

    # Let the boot loader finish writing to SDRAM and the REPL start.
    time.sleep(args.boot_wait)
    sys.stdout.write(drain(fd, 0.5).decode("latin-1"))
    sys.stdout.flush()

    for cmd in args.commands:
        sys.stderr.write("TEST: -> %s\n" % cmd)
        sys.stderr.flush()
        write_all(fd, (cmd + "\r\n").encode("latin-1"))
        time.sleep(args.post_delay)
        sys.stdout.write(drain(fd, args.idle).decode("latin-1"))
        sys.stdout.flush()

    sys.stderr.write("TEST: waiting %gs of silence before exit\n" % args.idle)
    sys.stderr.flush()
    sys.stdout.write(drain(fd, args.idle).decode("latin-1"))
    sys.stdout.flush()
    os.close(fd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
