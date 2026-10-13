#!/usr/bin/env python3
"""Read the boot forensic records over the DMI system bus.

Works even when the CPU is wedged or abstract commands are unsupported:
the system bus does not touch the hart.  Reads the GPIO LEDs (the
pre-SDRAM-init progress channel) and the SDRAM progress/trap records
written by boot_loader.c's forensic recorder.

Usage: python3 scripts/forensic_read.py [port]
"""
import sys
sys.path.insert(0, '/Users/npe/src/ulx3s-experiments/flute-ulx3s/scripts')
import dmi as D

FOREN_BASE = 0x81FFFF80
FOREN_MAGIC_PGRS = 0xF0E1D2C3
FOREN_MAGIC_TRAP = 0x7A9C4E1F
GPIO_BASE = 0xC0002000

PGRS_STEPS = {
    1: 'SDRAM readback OK',
    2: 'banner printing',
    3: 'load protocol idle (waiting for header)',
    4: 'image header received',
    5: 'chunked image load done',
    6: 'load done (readback printed)',
    7: 'repair window',
    8: 'jumping to kernel',
}

MCAUSE = {
    0: 'instr fetch address misaligned',
    1: 'instr access fault',
    2: 'illegal instruction',
    3: 'breakpoint',
    4: 'load address misaligned',
    5: 'load access fault',
    6: 'store/AMO address misaligned',
    7: 'store/AMO access fault',
    8: 'ECALL from U',
    9: 'ECALL from S',
    11: 'ECALL from M',
    12: 'instr page fault',
    13: 'load page fault',
    15: 'store/AMO page fault',
}


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else '/dev/cu.usbserial-120001'
    d = D.DMI(port, 625000)
    d.arm()

    leds = d.mem_read32(GPIO_BASE)
    print(f'LEDs (GPIO)      = 0x{leds & 0xff:02x}')

    try:
        w = d.mem_read(FOREN_BASE, 10)
    except RuntimeError as e:
        print(f'forensic slot unreadable: {e}')
        print('(boot never reached a working SDRAM, or the memory system'
              ' itself is the fault -- rely on the LEDs above)')
        return

    p_magic, p_step, _, _, t_magic, mcause, mepc, mtval, mstatus, t_count = w

    if p_magic == FOREN_MAGIC_PGRS:
        what = PGRS_STEPS.get(p_step, f'unknown step {p_step}')
        print(f'boot progress    = {p_step}  ({what})')
    else:
        print(f'boot progress    = none (magic 0x{p_magic:08x})')

    if t_magic == FOREN_MAGIC_TRAP:
        intr = bool(mcause & 0x80000000)
        code = mcause & 0x7fffffff
        what = MCAUSE.get(code, f'code {code}')
        kind = 'interrupt' if intr else 'exception'
        print(f'TRAP count       = {t_count}')
        print(f'last trap        = {kind} {code} ({what})')
        print(f'  mcause         = 0x{mcause:08x}')
        print(f'  mepc           = 0x{mepc:08x}')
        print(f'  mtval          = 0x{mtval:08x}')
        print(f'  mstatus        = 0x{mstatus:08x}')
        if t_count and t_count > 20:
            print('  (count high: the CPU was trap-LOOPING)')
    else:
        print(f'trap record      = none (magic 0x{t_magic:08x})')


if __name__ == '__main__':
    main()
