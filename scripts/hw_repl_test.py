#!/usr/bin/env python3
"""HW REPL end-to-end with the v11 chunked load protocol.

Boot ROM v11: header (addr,len LE) then 256-byte chunks framed as
[seq, data, XOR] with seq = chunk index & 0xFF; each chunk is sent as
ONE write so the host USB stack coalesces the burst.  Per chunk the ROM
ACKs (0x06) or, after a seq/checksum mismatch or receive stall, drains
the RX pipe for ~0.5 s (the failed chunk's tail is still in the
macOS/FTDI/USB buffers) and NAKs (0x15).  The host resends the chunk on
NAK or 2.5 s silence.  After the last chunk: CRLF +
"[first-8-words : last-8-words]" readback (both ends are checked so a
lost-ACK one-chunk shift is caught), ~24 s repair window, jump.
Then the REPL boots; we wait for the prompt, send 1+1; and Sys;.

If a chunk fails 8 retries the loader closes the port, reprograms the
FPGA (30 s, bulletproof reset), and restarts the whole image.
"""
import os, termios, fcntl, time, struct, subprocess, sys

PORT = '/dev/cu.usbserial-120001'
BAUD = 625000
CHUNK = 256
BITSTREAM = 'build/ulx3s_top.bit'
blob = open('templeos/build/ulx3s_repl.blob.bin', 'rb').read()
chunks = (len(blob) + CHUNK - 1) // CHUNK


def open_port():
    # The FTDI re-enumerates after openFPGALoader releases it; the first
    # tcsetattr on a freshly-appeared device can fail with EINVAL.  Retry.
    for attempt in range(10):
        fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        try:
            attrs = termios.tcgetattr(fd)
            attrs[0] = attrs[1] = attrs[3] = 0
            attrs[2] = termios.CREAD | termios.CLOCAL | termios.CS8
            termios.tcsetattr(fd, termios.TCSANOW, attrs)
            fcntl.ioctl(fd, 0x80045402, struct.pack('I', BAUD))
            return fd
        except (termios.error, OSError):
            os.close(fd)
            time.sleep(0.3)
    raise RuntimeError('open_port: device not ready after reprogram')


def drain(fd, t):
    time.sleep(t); d = b''
    try:
        while True: d += os.read(fd, 65536)
    except (BlockingIOError, OSError): pass
    return d


_leftover = b''
# Bytes read past the ACK in the same syscall (e.g. the ROM's "\r\n[readback]"
# arriving coalesced with the final 0x06).  Discarding them once made the
# readback phase miss its '\r\n[' break and swallow the entire boot.


def wait_ack(fd, timeout):
    """Return (b'\\x06'|b'\\x15'|None, leftover): status plus any bytes read
    past the status byte in the same syscall (kept for the caller to seed
    the next phase — the ROM's readback line can follow the last ACK in one
    USB packet)."""
    global _leftover
    t0 = time.time()
    buf = _leftover
    _leftover = b''
    while time.time() - t0 < timeout:
        try:
            d = os.read(fd, 64)
            if d:
                buf += d
                i = buf.find(b'\x06')
                if i >= 0:
                    _leftover = buf[i + 1:]
                    return b'\x06', _leftover
                i = buf.find(b'\x15')
                if i >= 0:
                    _leftover = buf[i + 1:]
                    return b'\x15', _leftover
        except (BlockingIOError, OSError):
            pass
        time.sleep(0.001)
    _leftover = buf
    return None, b''


fd = None
def reprogram():
    global fd
    if fd is not None:
        try: os.close(fd)
        except OSError: pass
    sys.stderr.write('reprogramming FPGA (clean slate)...\n')
    subprocess.run(['openFPGALoader', '-b', 'ulx3s', '-m', BITSTREAM],
                   capture_output=True)
    fd = open_port()
    drain(fd, 2.0)


reprogram()
nak_ct = 0


def write_chunk(data):
    """os.write with retry: macOS tty writes can fail with EIO on a USB
    hiccup; reopen the port and retry rather than losing the whole load."""
    global fd
    for attempt in range(4):
        try:
            os.write(fd, data)
            return
        except OSError:
            if attempt == 3:
                raise
            try:
                os.close(fd)
            except OSError:
                pass
            time.sleep(0.5)
            fd = open_port()
            drain(fd, 0.2)


def load_image(max_full=3):
    global nak_ct
    for full in range(max_full):
        drain(fd, 0.5)
        write_chunk(struct.pack('<II', 0x80000000, len(blob)))
        t0 = time.time()
        for ci in range(chunks):
            off = ci * CHUNK
            ck = blob[off:off + CHUNK]
            x = 0
            for b in ck: x ^= b
            for retry in range(8):
                # [seq, data, xor, 0x55 pad] in one coalesced write; the
                # pad keeps the checksum byte from being last on the
                # wire (a trailing 0xDB would be held by the DMI bridge)
                write_chunk(bytes([ci & 0xFF]) + ck + bytes([x, 0x55]))
                r, _ = wait_ack(fd, 2.5)        # covers ROM's 0.5s drain + NAK
                if r == b'\x06':
                    break
                nak_ct += 1
            else:
                sys.stderr.write(f'chunk {ci} failed 8 retries\n')
                reprogram()
                break
            if ci % 512 == 0:
                sys.stderr.write(f'  chunk {ci}/{chunks} '
                                 f'({time.time()-t0:.0f}s, nak={nak_ct})\n')
        else:
            sys.stderr.write(f'sent {len(blob)} in {time.time()-t0:.0f}s '
                             f'({chunks} chunks, {nak_ct} NAKs)\n')
            return True
    return False

if not load_image():
    print('LOAD FAILED'); sys.exit(1)

# collect readback + repair-window output, then REPL banner.  Seed with any
# bytes the final wait_ack read past the ACK (the readback line can be
# coalesced into the same USB packet as the last 0x06).
allout = _leftover
_leftover = b''
t0 = time.time()
while time.time() - t0 < 60:
    d = drain(fd, 1.0)
    if d: allout += d
    if allout.count(b'\r\n['): break
i = allout.rfind(b'\r\n[')
if i >= 0:
    line = allout[i:i+200].split(b']')[0] + b']'
    body = line.strip()[1:-1]
    sys.stderr.write(f'readback: {line.decode()}\n')
    parts = body.split(b' : ')
    head = parts[0].split()
    ok = head == [b'%08x' % v for v in struct.unpack('<8I', blob[:32])]
    if len(parts) > 1:
        tail = parts[1].split()
        ok = ok and tail == [b'%08x' % v
                             for v in struct.unpack('<8I', blob[-32:])]
    if not ok:
        sys.stderr.write('READBACK MISMATCH (head or tail)\n')
        print('READBACK MISMATCH'); sys.exit(1)
sys.stderr.write('verified; through repair window + REPL boot...\n')

got = False
t0 = time.time()
while time.time() - t0 < 240:
    d = drain(fd, 2.0)
    if d:
        allout += d
        # prompt: scan a tail window (the REPL emits control bytes around
        # the prompt in some boots, so a strict endswith flakes)
        if b'\r\n> ' in allout[-4096:] or b'> ' in allout[-8:]:
            got = True
            break
if not got:
    sys.stderr.write(f'[dbg] prompt timeout: allout={len(allout)}B elapsed={time.time()-t0:.0f}s '
                     f'tail={allout[-120:]!r}\n')
print('=== REPL output (last 2000 chars) ===')
print(allout.decode('latin-1')[-2000:])
if got:
    os.write(fd, b'1+1;\r\n')
    d = drain(fd, 25.0)
    print('=== after 1+1; ===')
    print(d.decode('latin-1')[-1000:])
    # The full eval dispatch must produce ans=2 (JIT compile + run + print).
    tail = d.split(b'ans=')[-1][:40].replace(b'\r', b'')
    if b'ans=' not in d or b'=2\n' not in tail:
        print('EVAL FAIL: 1+1; did not print ans=...=2')
        os.close(fd)
        sys.exit(3)
    print('EVAL OK: 1+1; -> ans=2')
    os.write(fd, b'Sys;\r\n')
    d = drain(fd, 15.0)
    print('=== after Sys; (mem section) ===')
    t = d.decode('latin-1')
    i = t.find('--- mem ---')
    print(t[i:i+400] if i >= 0 else t[-400:])
os.close(fd)
sys.exit(0 if got else 2)
