#!/usr/bin/env python3
"""Load the bare-metal cache test into the ULX3S and capture UART output.
Usage: python3 run_cache_test.py [bitstream] [blob]   (blob default test/cache_test.bin;
test/amo_test.bin uses the same T/M/D protocol)"""
import sys, os, time, subprocess
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'scripts'))
# Paths on the command line are relative to the caller's cwd; defaults to the repo root.
args = [os.path.abspath(a) for a in sys.argv[1:]]
os.chdir(ROOT)
import hw_test_suite as H

bit = args[0] if len(args) > 0 else 'build/ulx3s_top.bit'
r = subprocess.run(['openFPGALoader', '-b', 'ulx3s', '-m', bit], capture_output=True, text=True)
print('program rc=', r.returncode)
fd = H.open_port()
blob = open(args[1] if len(args) > 1 else 'test/cache_test.bin', 'rb').read()
H.drain(fd, 3.0)
boot = H.drain(fd, 1.0)
H.load_blob(fd, blob)
print('loaded', len(blob), 'bytes')
t0 = time.time()
out = b''
while time.time() - t0 < 30:
    out += H.drain(fd, 1.0)
    if b'D' in out:
        break
print('raw:', repr(out))
# decode: expect 'T' then optional M<hex><hex><hex> lines, then 'D'
s = out.decode('latin-1', 'replace')
print('decoded:', s.replace('\r', ' '))
if b'D' in out:
    print('RESULT: PASS (D seen)')
elif out.startswith(b'T'):
    print('RESULT: FAIL (no D; mismatches above)')
else:
    print('RESULT: NO OUTPUT (did not even print T)')
os.close(fd)
