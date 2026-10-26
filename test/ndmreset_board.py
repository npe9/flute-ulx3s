#!/usr/bin/env python3
"""Board test of the debug-module SoC reset (ndmreset) with Linux running.

Boots Linux, lets it run, pulses dmcontrol.ndmreset over the UART DMI bridge
(SoC_Top.rl_ndm_reset_start: core, Mem_Controller and fabric reset, the
Sdram_Controller is not), then reloads and reboots Linux on the same port.
Linux keeps the SDRAM busy (I$/D$ refills), so the reset usually lands with
raw reads in flight: before the Mem_Controller drain fix their chunks were
delivered as data of the next reads.

PASS: every cycle reaches the boot banner, loads, and Linux ticks again
(TICKS ticks, "fp ok") with no panic / Oops.

Usage: ndmreset_board.py <fw_payload.bin> [-n cycles] [-p port]
Program the FPGA first.  Holds the serial port for the whole run.
"""
import argparse, os, struct, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts"))
import dmi as dmimod                                   # noqa: E402
sys.path.insert(0, os.path.join(HERE, "..", "..", "flute-ulx3s", "scripts"))
import loader                                          # noqa: E402

DMCONTROL = 0x10
BAD = (b"Kernel panic", b"Oops", b"Unable to handle", b"BUG:", b"fp BAD", b"illegal instruction")


def wait_for(fd, pats, timeout, log):
    """Read until any of pats (bytes) appears; return (pat, buf) or (None, buf)."""
    buf = b""
    end = time.time() + timeout
    while time.time() < end:
        chunk = loader.read_avail(fd, 0.5)
        if chunk:
            log.write(chunk); log.flush()
            buf += chunk
            for b in BAD:
                if b in buf:
                    return b, buf
            for p in pats:
                if p in buf:
                    return p, buf
            buf = buf[-4096:]
    return None, buf


def arm_checked(d):
    """Arm, then a framing canary: data0 (0x04) is scratch, so a write/read-back of a fresh
    token proves request and response streams are aligned (an offset makes every read return
    the previous op's data)."""
    d.arm()
    tok = int(time.time() * 1000) & 0xFFFFFFFF
    d.wr(0x04, tok)
    got = d.rd(0x04)
    if got != tok:
        raise RuntimeError("DMI framing canary: wrote %#x, read %#x" % (tok, got))


def load_blob_logged(fd, blob, log, dst=0x80000000):
    """loader.load_blob with every received byte logged (hex, per chunk attempt): 0xDB frames
    mean the bridge was still armed, 'N ...' lines are ROM NAKs, silence means nothing reached
    the ROM or nothing came back."""
    loader.drain(fd, 2.0)
    os.write(fd, struct.pack('<II', dst, len(blob)))
    for ci in range((len(blob) + 255) // 256):
        ck = blob[ci * 256:(ci + 1) * 256]
        x = 0
        for b in ck:
            x ^= b
        for retry in range(8):
            os.write(fd, bytes([ci & 0xFF]) + ck + bytes([x, 0x55]))
            buf = b''
            t0 = time.time()
            ok = False
            while time.time() - t0 < 2.5:
                dd = loader.read_avail(fd, 0.1)
                if dd:
                    buf += dd
                    if b'\x06' in buf:
                        ok = True
                        break
                    if b'\x15' in buf:
                        break
            if ci == 0 or not ok:
                log.write(b"\n[ndmreset] chunk %d try %d rx %d bytes: %s\n"
                          % (ci, retry, len(buf), buf[:120].hex().encode()))
                log.flush()
            if ok:
                break
        else:
            raise RuntimeError('load failed at chunk %d' % ci)


def load(fd, payload, log, banner_wait):
    """Wait for the banner, then load. The bridge holds console output back while it is armed,
    so the banner printed right after an ndmreset can be lost: without it, load anyway -- the
    ROM's framed protocol is ACK-paced, so a dead SoC still fails the load."""
    pat, _ = wait_for(fd, [loader.BANNER], banner_wait, log)
    if pat is not None and pat != loader.BANNER:
        return "bad output before load (%r)" % (pat,)
    if pat is None:
        log.write(b"\n[ndmreset] no banner seen; loading anyway\n")
    t0 = time.time()
    try:
        load_blob_logged(fd, payload, log)
    except Exception as e:                      # noqa: BLE001
        return "load failed (%s)" % (e,)
    log.write(b"\n[ndmreset] loaded in %.1fs\n" % (time.time() - t0)); log.flush()
    return None


def boot(fd, payload, ticks, log, banner_wait=30):
    err = load(fd, payload, log, banner_wait)
    if err:
        return err
    pat, _ = wait_for(fd, [b"tick %d " % ticks], 180, log)
    if pat != b"tick %d " % ticks:
        return "no tick %d (%r)" % (ticks, pat)
    return None


def diagnose(d, log):
    """After a failed cycle: where is the hart?  dmstatus, dpc/mcause/mepc (halts the hart),
    the boot ROM's forensic progress word (0x81FFFF80: magic, step; 2 = banner loop, 3 = load
    wait, 4 = header received) and the milestone LEDs."""
    out = []
    d.buf = b""
    try:
        arm_checked(d)
        st = d.rd(0x11)
        hart = ("UNAVAILABLE (hart held in reset: the SoC reset never completed)" if st & (1 << 13)
                else "halted" if st & (1 << 9) else "running" if st & (1 << 11) else "?")
        out.append("dmstatus %#x (%s) dmcontrol %#x" % (st, hart, d.rd(0x10)))
        for name, f in [("leds", lambda: hex(d.mem_read(0xC0002000, 1)[0])),
                        ("foren", lambda: " ".join("%#x" % w for w in d.mem_read(0x81FFFF80, 10))),
                        ("halt", lambda: d.halt()),
                        ("dpc", lambda: hex(d.read_csr(0x7b1))),
                        ("mcause", lambda: hex(d.read_csr(0x342))),
                        ("mepc", lambda: hex(d.read_csr(0x341)))]:
            try:
                out.append("%s %s" % (name, f()))
            except Exception as e:              # noqa: BLE001
                out.append("%s FAILED (%s)" % (name, e))
        d.resume()
        d.disarm()
        # Does a console byte reach the ROM?  From the banner loop (step 2) one byte moves it
        # to the load protocol (step 3); if it does not, the RX path to the ROM is dead.
        os.write(d.fd, b"\x00")
        time.sleep(0.2)
        d.buf = b""
        arm_checked(d)
        out.append("after one console byte: foren step %#x" % d.mem_read(0x81FFFF84, 1)[0])
        d.disarm()
    except Exception as e:                      # noqa: BLE001
        out.append("diagnose aborted (%s)" % (e,))
    msg = "[ndmreset] diag: " + "; ".join(out)
    print(msg, flush=True)
    log.write(b"\n" + msg.encode() + b"\n"); log.flush()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image")
    ap.add_argument("-n", "--cycles", type=int, default=5)
    ap.add_argument("-p", "--port", default="/dev/cu.usbserial-120001")
    ap.add_argument("--ticks", type=int, default=5, help="ticks to wait for after each boot")
    ap.add_argument("--log", default="ndmreset_board.log")
    ap.add_argument("--busy", action="store_true",
                    help="reset 0.3-2.5 s into each Linux boot (constant I$ refills) instead of while idle")
    args = ap.parse_args()
    payload = open(args.image, "rb").read()
    log = open(args.log, "wb")

    d = dmimod.DMI(args.port)        # opens the port; the bridge stays disarmed until a request
    fd = d.fd
    err = boot(fd, payload, args.ticks, log)
    print("[ndmreset] initial boot:", err or "ok", flush=True)
    if err:
        diagnose(d, log)
        return 1
    import random
    fails = 0
    passed = 0
    for i in range(1, args.cycles + 1):
        d.buf = b""
        try:
            arm_checked(d)
            d.wr(DMCONTROL, 0x3)      # dmactive | ndmreset
            d.wr(DMCONTROL, 0x1)      # release
            d.disarm()                # console pass-through again
            err = None
        except Exception as e:        # noqa: BLE001
            err = "reset sequence failed (%s)" % (e,)
        if err:
            pass
        elif args.busy and i < args.cycles:
            # load, let Linux boot for a moment, and reset again next iteration
            err = load(fd, payload, log, 5)
            if not err:
                dt = random.uniform(0.3, 2.5)
                log.write(b"\n[ndmreset] reset after %.2fs of boot\n" % dt); log.flush()
                pat, _ = wait_for(fd, [], dt, log)
                if pat is not None:
                    err = "bad output during boot (%r)" % (pat,)
        else:
            err = boot(fd, payload, args.ticks, log, banner_wait=5)
        print("[ndmreset] cycle %d: %s" % (i, err or "ok"), flush=True)
        if err:
            diagnose(d, log)
            fails += 1
            break
        passed += 1
    print("[ndmreset] %s: %d/%d cycles passed" % ("PASS" if fails == 0 else "FAIL", passed, args.cycles))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
