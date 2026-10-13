#!/usr/bin/env python3
"""Resilient DMI client for a crash-looping CPU drowning the UART in spam."""
import sys, os, time, struct, select
sys.path.insert(0, '/Users/npe/src/ulx3s-experiments/flute-ulx3s/scripts')
import dmi as D
import hw_test_suite as H

fd = H.open_port()
H.drain(fd, 0.5)

def transact(op, addr, data, timeout=1.0):
    os.write(fd, bytes([op, addr & 0x7F]) + struct.pack(">I", data & 0xFFFFFFFF))
    buf = b""
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                buf += os.read(fd, 4096)
            except OSError:
                pass
        # scan for any complete frames; 0xDB may appear in spam so try every offset
        i = 0
        while True:
            j = buf.find(b"\xdb", i)
            if j < 0 or len(buf) < j + 6:
                break
            frame = buf[j:j+6]
            # validate: plausible status byte (0/2) and not all-garbage
            st = frame[1]
            if st == 0:
                val = struct.unpack(">I", frame[2:])[0]
                return val
            i = j + 1
        buf = buf[-64:]  # keep tail only
    return None

# strategy: keep sending MAGIC+rd(dmstatus) until version nibble == 2
DMSTATUS = 0x11
for attempt in range(40):
    os.write(fd, D.MAGIC)
    time.sleep(0.02)
    v = transact(ord("r"), DMSTATUS, 0, timeout=0.6)
    if v is not None and (v & 0xF) == 2:
        print(f"armed after {attempt} attempts, dmstatus={v:#010x}")
        break
else:
    print("could not arm")
    sys.exit(1)

halted = False
for attempt in range(20):
    # haltreq: dmcontrol = 0x80000001  (haltreq | dmactive)
    transact(ord("w"), 0x10, 0x80000001, timeout=0.5)
    v = transact(ord("r"), DMSTATUS, 0, timeout=0.5)
    if v is not None and (v & 0x100):
        print("halted")
        halted = True
        break
if not halted:
    print("halt did not confirm, trying anyway")

CSR_DPC = 0x7B1
dpc = transact(ord("R") if False else ord("r"), CSR_DPC & 0x7F, 0, timeout=1.0)
print(f"dpc = {dpc:#010x}" if dpc is not None else "dpc read failed")
CSR_MEPC = 0x341
mepc = transact(ord("r"), CSR_MEPC & 0x7F, 0, timeout=1.0)
print(f"mepc = {mepc:#010x}" if mepc is not None else "mepc read failed")
os.close(fd)
