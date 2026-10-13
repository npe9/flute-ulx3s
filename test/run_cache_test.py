#!/usr/bin/env python3
"""Load the bare-metal cache test into the ULX3S and capture UART output.
Usage: python3 run_cache_test.py [bitstream]"""
import sys, os, time, subprocess
sys.path.insert(0, '/Users/npe/src/ulx3s-experiments/flute-ulx3s/scripts')
os.chdir('/Users/npe/src/ulx3s-experiments/flute-ulx3s')
import hw_test_suite as H

bit = sys.argv[1] if len(sys.argv) > 1 else 'build/ulx3s_top.bit'
r = subprocess.run(['openFPGALoader', '-b', 'ulx3s', '-m', bit], capture_output=True, text=True)
print('program rc=', r.returncode)
fd = H.open_port()
blob = open('test/cache_test.bin', 'rb').read()
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
