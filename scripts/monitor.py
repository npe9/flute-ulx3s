#!/usr/bin/env python3
"""Load the TempleOS monitor and run a short smoke test over UART."""

import os
import select
import struct
import sys
import termios
import time

PORT = "/dev/cu.usbserial-120001"
BAUD = termios.B115200
BANNER = b"boot loader\r\n"
IMAGE = os.path.join(os.path.dirname(__file__), "..", "templeos", "build", "monitor", "monitor.bin")
PACE = 0.0001


def open_serial(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    attrs[4] = attrs[5] = BAUD
    attrs[2] |= termios.CLOCAL | termios.CREAD
    attrs[2] &= ~termios.CSIZE
    attrs[2] |= termios.CS8
    attrs[2] &= ~(termios.PARENB | termios.CSTOPB | termios.CRTSCTS)
    attrs[3] &= ~(termios.ICANON | termios.ECHO | termios.ISIG | termios.IEXTEN)
    attrs[0] &= ~(termios.IXON | termios.IXOFF | termios.ICRNL | termios.INLCR | termios.IGNCR)
    attrs[1] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def read_avail(fd, timeout):
    r, _, _ = select.select([fd], [], [], timeout)
    if not r:
        return b""
    try:
        return os.read(fd, 4096)
    except BlockingIOError:
        return b""


def expect_prompt(fd, deadline):
    buf = b""
    while time.time() < deadline:
        buf += read_avail(fd, 0.2)
        if b"> " in buf:
            return buf
    sys.stdout.buffer.write(buf)
    sys.stdout.flush()
    raise RuntimeError("prompt not seen")


def main():
    image = open(IMAGE, "rb").read()
    fd = open_serial(PORT)

    # wait for boot banner
    sys.stderr.write("monitor: waiting for boot banner ...\n")
    buf = b""
    deadline = time.time() + 20
    while BANNER not in buf:
        if time.time() > deadline:
            sys.stderr.write("monitor: TIMEOUT waiting for banner\n")
            return 1
        buf += read_avail(fd, 0.5)
    sys.stdout.buffer.write(buf)

    # send header + payload paced
    os.write(fd, struct.pack("<II", 0x80000000, len(image)))
    sys.stderr.write("monitor: sending %d bytes ...\n" % len(image))
    for b in image:
        os.write(fd, bytes([b]))
        time.sleep(PACE)

    # wait for initial prompt
    out = expect_prompt(fd, time.time() + 10)
    sys.stdout.buffer.write(out)
    sys.stdout.flush()

    commands = [b"h\r", b"r 80000000\r", b"w 80001000 deadbeef\r", b"r 80001000\r", b"r c0000000\r", b"g 80000000\r"]
    for cmd in commands:
        sys.stdout.buffer.write(b"\n[" + cmd + b"]\n")
        sys.stdout.flush()
        os.write(fd, cmd)
        # give monitor time to respond
        time.sleep(0.2)
        out = b""
        deadline = time.time() + 2
        while time.time() < deadline:
            chunk = read_avail(fd, 0.1)
            if chunk:
                out += chunk
            else:
                break
        sys.stdout.buffer.write(out)
        sys.stdout.flush()

    sys.stderr.write("monitor: smoke test done\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
