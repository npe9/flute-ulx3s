#!/usr/bin/env python3
"""Board bench for the HolyC REPL's ULX3S drivers (templeos/ulx3s_repl/ulx3s_drv.hc).

Programs the bitstream, loads the REPL blob, then checks: BoardHelp, the RTC (it answers and its
seconds advance), buttons and DIP switches (read, nothing pressed), BtnWait timeout, Sleep timing,
and the tone generator by register readback at volume 0 (silent).  Never calls PowerOff, PowerOffFor
or Reconf.  --set-rtc sets the RTC to the host's UTC time first.

  HW_BITSTREAM=build/lx43/ulx3s_top.bit python3 scripts/hw_board_drv.py --blob templeos/build-drv/repl.blob.bin
"""
import argparse
import datetime
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hw_test_suite as hw  # noqa: E402


def ans(out):
    m = re.findall(r'ans=0x([0-9a-fA-F]+)', out)
    return int(m[-1], 16) & 0xFFFFFFFF if m else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--blob', default=hw.BLOB)
    ap.add_argument('--set-rtc', action='store_true', help='set the RTC to the host UTC time')
    args = ap.parse_args()
    subprocess.run(['openFPGALoader', '-b', 'ulx3s', '-m', hw.BITSTREAM], capture_output=True)
    fd = hw.open_port()
    hw.load_blob(fd, open(args.blob, 'rb').read())
    boot = b''
    t0 = time.time()
    while time.time() - t0 < 240:
        boot += hw.drain(fd, 2.0)
        if boot.endswith(b'> '):
            break
    if not boot.endswith(b'> '):
        print('REPL never reached a prompt')
        return 1
    print('REPL up.', flush=True)
    R = 'required'
    hw.check_repl(R, 'BoardHelp', fd, 'BoardHelp;', expect=('RtcShow()', 'PowerOffFor'))
    if args.set_rtc:
        now = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=1)
        out = hw.check_repl(R, 'RtcSet (host UTC)', fd,
                            f'RtcSet({now.year},{now.month},{now.day},{now.hour},{now.minute},{now.second});')
        if out is not None and ans(out) != 1:
            hw.record(R, 'RtcSet returns 1', 'FAIL', out[-120:])
    out1 = hw.check_repl(R, 'RtcShow', fd, 'RtcShow;', expect=('20',), forbid=('FAULT', 'no answer'))
    h1 = time.time()
    t1 = time.time()
    hw.send_line(fd, 'Sleep(2000);')
    t2 = time.time()
    out2 = hw.check_repl(R, 'RtcShow again', fd, 'RtcShow;', expect=('20',), forbid=('FAULT', 'no answer'))
    h2 = time.time()
    if out1 and out2:
        a, b = ans(out1), ans(out2)
        line = [ln for ln in out2.split('\r\n') if re.match(r'\s*20\d\d-', ln)]
        print('    rtc: ' + (line[-1].strip() if line else '?'))
        # each REPL line costs ~1.5 s of settle, so compare with the host clock over the same span
        d = (b - a) % 86400 if a is not None and b is not None else None
        ok = d is not None and abs(d - (h2 - h1)) <= 1.5
        hw.record(R, 'RTC advances with the host clock', 'PASS' if ok else 'FAIL',
                  f'rtc {d} s, host {h2 - h1:.1f} s')
        for flag in ('oscillator stopped', 'battery backup off'):
            if flag in out2:
                hw.record(R, f'RTC not "{flag}"', 'FAIL', 'RtcSet fixes it (--set-rtc)')
    dt = t2 - t1
    hw.record(R, 'Sleep(2000) takes ~2 s', 'PASS' if 3.3 < dt < 4.5 else 'FAIL', f'{dt:.2f} s round trip, 1.5 s of it settle')
    out = hw.check_repl(R, 'Btns (none pressed)', fd, 'Btns;', expect=('ans=',))
    if out is not None and ans(out) != 0:
        hw.record(R, 'Btns reads 0', 'FAIL', hex(ans(out)))
    out = hw.check_repl(R, 'Sws', fd, 'Sws;', expect=('ans=',))
    if out is not None:
        print(f'    switches: {ans(out)}')
    out = hw.check_repl(R, 'BtnWait(500) times out', fd, 'BtnWait(500);', expect=('ans=',))
    if out is not None and ans(out) != 0xFFFFFFFF:
        hw.record(R, 'BtnWait returns -1', 'FAIL', hex(ans(out)))
    hw.send_line(fd, 'SndVol(0);')
    hw.send_line(fd, 'Snd(60);')
    tone = ans(hw.send_line(fd, 'BrdRd(0xC0009010);'))
    ctrl = ans(hw.send_line(fd, 'BrdRd(0xC0009004);'))
    vol = ans(hw.send_line(fd, 'BrdRd(0xC0009008);'))
    hw.send_line(fd, 'Snd(0);')
    ctrl0 = ans(hw.send_line(fd, 'BrdRd(0xC0009004);'))
    exp = 50000000 // 2 // 440 - 1
    ok = tone == exp and ctrl is not None and ctrl & 2 and vol == 0 and ctrl0 is not None and not ctrl0 & 2
    hw.record(R, 'Snd(60) = 440 Hz at volume 0, Snd(0) off', 'PASS' if ok else 'FAIL',
              f'TONE {tone} (exp {exp}) CTRL {ctrl} VOL {vol} after-off CTRL {ctrl0}')
    hw.check_repl(R, 'I2cRd no device (0x20)', fd, 'I2cRd(0x20, 0);', expect=('ans=0xffffffff',))
    n_fail = sum(1 for r in hw.results if r[2] == 'FAIL')
    print(f'== summary: {sum(1 for r in hw.results if r[2] == "PASS")} PASS, {n_fail} FAIL ==')
    return 1 if n_fail else 0


if __name__ == '__main__':
    sys.exit(main())
