#!/usr/bin/env python3
"""Controlled chunk-failure experiments against the v9 boot ROM.

Usage: exp_chunk2.py reprogram   (once, to reset the board)
       exp_chunk2.py load <file> [nchunks]   (run a synthetic load, log every response)

Each failed run leaves the ROM wedged in its chunk-retry loop, so every
experiment that doesn't complete cleanly must be preceded by a reprogram.
"""
import os, termios, fcntl, time, struct, subprocess, sys

PORT = '/dev/cu.usbserial-120001'
BAUD = 625000
CHUNK = 256
BITSTREAM = 'build/ulx3s_top.bit'

def open_port():
    fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = a[1] = a[3] = 0
    a[2] = termios.CREAD | termios.CLOCAL | termios.CS8
    termios.tcsetattr(fd, termios.TCSANOW, a)
    fcntl.ioctl(fd, 0x80045402, struct.pack('I', BAUD))
    return fd

def drain(fd, t):
    time.sleep(t); d = b''
    try:
        while True: d += os.read(fd, 65536)
    except (BlockingIOError, OSError): pass
    return d

def wait_ack(fd, timeout):
    t0 = time.time()
    buf = b''
    while time.time() - t0 < timeout:
        try:
            d = os.read(fd, 64)
            if d:
                buf += d
                if b'\x06' in buf: return b'\x06', buf
                if b'\x15' in buf:
                    # diagnostic NAK line ("N <seq> <xor> <flags>\r\n")
                    # follows the 0x15; give it a moment to arrive.
                    # Must stay well under the ROM's 48 ms getc_toh
                    # window or the retry outlives the ROM's patience.
                    time.sleep(0.005)
                    try:
                        while True: buf += os.read(fd, 256)
                    except (BlockingIOError, OSError): pass
                    return b'\x15', buf
        except (BlockingIOError, OSError):
            pass
        time.sleep(0.001)
    return None, buf

if sys.argv[1] == 'reprogram':
    subprocess.run(['openFPGALoader', '-b', 'ulx3s', '-m', BITSTREAM],
                   capture_output=True)
    fd = open_port(); drain(fd, 2.0); os.close(fd)
    print('reprogrammed + drained')
    sys.exit(0)

# load <file> [nchunks]
data = open(sys.argv[2], 'rb').read()
nchunks = int(sys.argv[3]) if len(sys.argv) > 3 else (len(data) + CHUNK - 1) // CHUNK
data = data[:nchunks * CHUNK]
fd = open_port()
drain(fd, 0.5)
os.write(fd, struct.pack('<II', 0x80000000, len(data)))
t0 = time.time()
for ci in range(nchunks):
    ck = data[ci*CHUNK:(ci+1)*CHUNK]
    x = 0
    for b in ck: x ^= b
    for retry in range(4):
        os.write(fd, bytes([ci & 0xFF]) + ck + bytes([x, 0x55]))
        r, buf = wait_ack(fd, 2.5)
        el = time.time() - t0
        if r == b'\x06':
            print(f'chunk {ci} try{retry}: ACK  ({el:.1f}s)')
            break
        print(f'chunk {ci} try{retry}: {r} raw={buf!r} ({el:.1f}s)')
    else:
        print(f'chunk {ci}: FAILED, board needs reprogram')
        os.close(fd); sys.exit(1)
print('ALL CHUNKS ACKED')
os.close(fd)
