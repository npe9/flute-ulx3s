#!/usr/bin/env python3
"""Full rescue DMI session: arm, halt, dump GPRs + key CSRs."""
import sys, os, time, struct, select
sys.path.insert(0, '/Users/npe/src/ulx3s-experiments/flute-ulx3s/scripts')
import dmi as D
import hw_test_suite as H

fd = H.open_port()
H.drain(fd, 0.3)

def transact(op, addr, data, timeout=1.0):
    os.write(fd, bytes([op, addr & 0x7F]) + struct.pack(">I", data & 0xFFFFFFFF))
    buf = b""; t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try: buf += os.read(fd, 4096)
            except OSError: pass
        i = 0
        while True:
            j = buf.find(b"\xdb", i)
            if j < 0 or len(buf) < j + 6: break
            st = buf[j+1]
            if st == 0:
                return struct.unpack(">I", buf[j+2:j+6])[0]
            i = j + 1
        buf = buf[-64:]
    return None

def arm():
    for _ in range(40):
        os.write(fd, D.MAGIC); time.sleep(0.02)
        v = transact(ord("r"), 0x11, 0, 0.6)
        if v is not None and (v & 0xF) == 2: return v
    return None

st = arm()
print(f"dmstatus={st:#010x}" if st is not None else "arm failed", flush=True)

DM_DMCONTROL=0x10; DM_COMMAND=0x17; DM_ABSTRACTCS=0x16; DM_DATA0=0x04
AC_READ = 0 << 16; AC_WRITE = 1 << 16

def wr(a, v): transact(ord("w"), a, v, 0.6)
def rd(a): return transact(ord("r"), a, 0, 0.6)

def abstract(write, regno, value=0):
    wr(DM_ABSTRACTCS, 0x700)
    if write: wr(DM_DATA0, value)
    wr(DM_COMMAND, (AC_WRITE if write else AC_READ) | regno)
    for _ in range(200):
        cs = rd(DM_ABSTRACTCS)
        if cs is None: time.sleep(0.01); continue
        if not (cs & 0x1000): break
        time.sleep(0.01)
    err = (cs >> 8) & 7
    if err: return f"ERR{err}"
    return rd(DM_DATA0)

# halt
wr(DM_DMCONTROL, 0x80000001)
time.sleep(0.2)
st = rd(0x11)
print(f"after halt dmstatus={st:#010x}", flush=True)

for regno, name in [(0x7B1,'dpc'), (0x341,'mepc'), (0x342,'mcause'), (0x343,'mtval'),
                    (0x305,'mtvec'), (0x300,'mstatus'), (0x304,'mie'), (0x344,'mip')]:
    v = abstract(False, regno)
    print(f"{name:>8} = {v if isinstance(v,str) else format(v,'#010x')}", flush=True)

for n in [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31]:
    v = abstract(False, 0x1000 + n)
    print(f"x{n:<3} = {v if isinstance(v,str) else format(v,'#010x')}", flush=True)
os.close(fd)
