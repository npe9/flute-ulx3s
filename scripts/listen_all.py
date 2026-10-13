#!/usr/bin/env python3
"""Listen on every /dev/cu.usbserial-* port at 115200 and print data as it arrives."""
import glob, os, sys, time, serial

ports = sorted(glob.glob('/dev/cu.usbserial-*'))
print(f"Listening on {len(ports)} ports...")
conns = {}
for p in ports:
    try:
        s = serial.Serial(p, 115200, timeout=0.1)
        conns[p] = s
    except Exception as e:
        print(f"skip {p}: {e}")

t0 = time.time()
while time.time() - t0 < 10.0:
    for p, s in list(conns.items()):
        try:
            data = s.read(256)
        except Exception as e:
            print(f"{p}: ERR {e}")
            del conns[p]
            continue
        if data:
            text = data.decode('latin-1', errors='replace')
            text = text.replace('\r', '\r').replace('\n', '\n')
            print(f"[{p}] {text!r}")
    time.sleep(0.05)

for s in conns.values():
    s.close()
