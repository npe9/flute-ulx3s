#!/usr/bin/env python3
"""Load a binary image into the ULX3S Flute SoC over the FTDI UART.

Waits for the boot loader banner, then sends:
  u32le dst address | u32le byte count | payload bytes
and relays any subsequent output (the program's own UART output) to
stdout until idle.

Uses only the Python standard library (termios + select).
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
        attrs[4] = attrs[5] = baud_const        # ispeed / ospeed
    else:
        # macOS/BSD: set arbitrary baud via IOSSIOSPEED after tcsetattr.
        attrs[4] = attrs[5] = termios.B115200
    attrs[2] |= termios.CLOCAL | termios.CREAD
    attrs[2] &= ~termios.CSIZE
    attrs[2] |= termios.CS8
    attrs[2] &= ~(termios.PARENB | termios.CSTOPB | termios.CRTSCTS)
    attrs[3] &= ~(termios.ICANON | termios.ECHO | termios.ISIG | termios.IEXTEN)
    attrs[0] &= ~(termios.IXON | termios.IXOFF | termios.ICRNL | termios.INLCR | termios.IGNCR)
    attrs[1] = 0                                 # VMIN/VTIME: pure timeout
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


def write_all(fd, data, chunk=4096):
    """Write all bytes, handling partial writes / EAGAIN on a non-blocking fd."""
    off = 0
    while off < len(data):
        _, w, _ = select.select([], [fd], [], None)
        if not w:
            continue
        try:
            n = os.write(fd, data[off:off + chunk])
        except BlockingIOError:
            continue
        if n == 0:
            raise OSError("write returned 0")
        off += n


def drain(fd, seconds):
    """Read and discard whatever arrives for `seconds` (sync the pipe)."""
    t0 = time.time()
    while time.time() - t0 < seconds:
        read_avail(fd, min(0.1, seconds - (time.time() - t0)))


def load_blob(fd, blob, dst=0x80000000):
    """Send header + payload in the ROM loader's CHUNKED framing
    (boot/boot_loader.c): header <II dst,len, then per chunk
    [seq=(off>>8)&0xFF, <=256 data bytes, xor of data, 0x55 pad].
    ACK-paced: the ROM replies 0x06 per good chunk, 0x15 (+diagnostic
    line) on mismatch; resend just that chunk.  The 0x55 pad guarantees
    the xor byte is never last on the wire (DMI-bridge 0xDB magic)."""
    drain(fd, 2.0)
    os.write(fd, struct.pack('<II', dst, len(blob)))
    for ci in range((len(blob) + 255) // 256):
        ck = blob[ci * 256:(ci + 1) * 256]
        x = 0
        for b in ck:
            x ^= b
        for _retry in range(8):
            os.write(fd, bytes([ci & 0xFF]) + ck + bytes([x, 0x55]))
            buf = b''
            t0 = time.time()
            ok = False
            while time.time() - t0 < 2.5:
                d = read_avail(fd, 0.1)
                if d:
                    buf += d
                    if b'\x06' in buf:
                        ok = True
                        break
                    if b'\x15' in buf:
                        break
            if ok:
                break
        else:
            raise RuntimeError('load failed at chunk %d' % ci)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("image", help="binary image to load")
    ap.add_argument("-p", "--port", default="/dev/cu.usbserial-120001")
    ap.add_argument("-b", "--baud", type=int, default=625000)
    ap.add_argument("-a", "--addr", default="0x80000000")
    ap.add_argument("-t", "--idle-timeout", type=float, default=5.0,
                    help="seconds of UART silence before exiting (0 = forever)")
    args = ap.parse_args()

    with open(args.image, "rb") as f:
        payload = f.read()
    dst = int(args.addr, 0)

    fd = open_serial(args.port, args.baud)

    # Wait for the boot loader banner (board may have just been reset).
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

    sys.stderr.write("loader: sending %d bytes to 0x%08x ...\n" % (len(payload), dst))
    t0 = time.time()

    # The ROM takes the framed-chunk path whenever dst and len are word-
    # aligned and len != 0; load_blob speaks it (ACK-paced, NAK-retry).
    # The old raw-stream path here only worked for unaligned/legacy loads.
    load_blob(fd, payload)
    sys.stderr.write("loader: sent in %.1fs; relaying program output\n"
                     % (time.time() - t0))

    # Relay program output until --idle-timeout seconds of silence.
    out = sys.stdout.buffer
    last_rx = time.time()
    while True:
        data = read_avail(fd, 0.25)
        if data:
            out.write(data)
            out.flush()
            last_rx = time.time()
        elif args.idle_timeout and (time.time() - last_rx > args.idle_timeout):
            break

    return 0


if __name__ == "__main__":
    sys.exit(main())
