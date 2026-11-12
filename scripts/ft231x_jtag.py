#!/usr/bin/env python3
"""Bit-banged JTAG on the ULX3S's FT231X (US1) through libftdi (ctypes), the way openFPGALoader does
it: TCK = DSR, TMS = DCD, TDI = RI, TDO = CTS, synchronous bitbang.  OpenOCD 0.12's ft232r driver
reads all ones on this chip, so this module either runs as an OpenOCD remote_bitbang server
(`--server PORT`, then openocd -f openocd/ulx3s_jtagg.ocd) or reads the IDCODE (`--idcode`).
While it runs the FT231X is not a UART; it is put back on exit (bitmode reset).
"""
import argparse, ctypes, socket, sys

TCK, TMS, TDI, TDO = 0x20, 0x40, 0x80, 0x08
BITMODE_RESET, BITMODE_SYNCBB = 0x00, 0x04

class Ftdi:
    def __init__(self, serial='120001', baud=1000000):
        self.l = ctypes.CDLL('/opt/homebrew/lib/libftdi1.2.dylib')
        self.l.ftdi_new.restype = ctypes.c_void_p
        self.l.ftdi_get_error_string.restype = ctypes.c_char_p
        for f in ('ftdi_usb_open_desc', 'ftdi_set_bitmode', 'ftdi_set_baudrate', 'ftdi_write_data',
                  'ftdi_read_data', 'ftdi_usb_close', 'ftdi_set_latency_timer', 'ftdi_tcioflush',
                  'ftdi_free', 'ftdi_get_error_string'):
            getattr(self.l, f).argtypes = [ctypes.c_void_p] + {
                'ftdi_usb_open_desc': [ctypes.c_int, ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p],
                'ftdi_set_bitmode': [ctypes.c_ubyte, ctypes.c_ubyte],
                'ftdi_set_baudrate': [ctypes.c_int],
                'ftdi_write_data': [ctypes.c_char_p, ctypes.c_int],
                'ftdi_read_data': [ctypes.c_char_p, ctypes.c_int],
                'ftdi_set_latency_timer': [ctypes.c_ubyte]}.get(f, [])
        self.c = self.l.ftdi_new()
        r = self.l.ftdi_usb_open_desc(self.c, 0x0403, 0x6015, None, serial.encode())
        if r < 0:
            raise OSError('ftdi open: ' + self.l.ftdi_get_error_string(self.c).decode())
        self.l.ftdi_set_latency_timer(self.c, 1)
        self.l.ftdi_set_baudrate(self.c, baud // 16)   # bitbang rate = 16 x the baud setting
        self.l.ftdi_set_bitmode(self.c, TCK | TMS | TDI, BITMODE_SYNCBB)
        self.l.ftdi_tcioflush(self.c)
        self.state = 0

    def xfer(self, data):
        """write pin bytes; sync bitbang returns one sampled byte per written byte"""
        out = b''
        for i in range(0, len(data), 256):
            ch = data[i:i + 256]
            self.l.ftdi_write_data(self.c, ch, len(ch))
            buf = ctypes.create_string_buffer(len(ch)); got = b''
            while len(got) < len(ch):
                n = self.l.ftdi_read_data(self.c, buf, len(ch) - len(got))
                if n < 0:
                    raise OSError('ftdi read')
                got += buf.raw[:n]
            out += got
        return out

    def close(self):
        self.l.ftdi_set_bitmode(self.c, 0, BITMODE_RESET)
        self.l.ftdi_usb_close(self.c)
        self.l.ftdi_free(self.c)

    # each bit: (tms, tdi) with TCK low, then TCK high; TDO sampled before the rising edge
    def shift(self, bits):
        b = bytearray()
        for tms, tdi in bits:
            v = (TMS if tms else 0) | (TDI if tdi else 0)
            b += bytes([v, v | TCK])
        r = self.xfer(bytes(b) + bytes([b[-1] & ~TCK]))
        return [1 if r[2 * i + 1] & TDO else 0 for i in range(len(bits))]

def idcode(f):
    f.shift([(1, 0)] * 6 + [(0, 0)])                 # TLR -> RTI
    f.shift([(1, 0), (0, 0), (0, 0)])                # Select-DR, Capture-DR, Shift-DR
    t = f.shift([(0, 0)] * 31 + [(1, 0)])            # 32 bits, last one exits
    f.shift([(1, 0), (0, 0)])                        # Update-DR, RTI
    return sum(b << i for i, b in enumerate(t))

def server(f, port):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(('127.0.0.1', port)); s.listen(1)
    print(f'remote_bitbang on 127.0.0.1:{port}', flush=True)
    while serve_one(f, s.accept()[0]):
        pass

TDI_EARLY = False   # --tdi-early


def serve_one(f, c):
    """one OpenOCD session; returns False after 'Q' (quit)"""
    pending = bytearray(); reads = []  # reads: indices into pending whose sample is wanted
    pins = 0
    def flush():
        nonlocal pending, reads
        if not pending:
            return b''
        r = f.xfer(bytes(pending))
        out = b''.join(b'1' if r[i] & TDO else b'0' for i in reads)
        pending = bytearray(); reads = []
        return out
    try:
        while True:
            d = c.recv(4096)
            if not d:
                break
            resp = b''
            for ch in d:
                ch = chr(ch)
                if '0' <= ch <= '7':
                    v = ord(ch) - 48           # bit 2 TCK, bit 1 TMS, bit 0 TDI
                    new = (TCK if v & 4 else 0) | (TMS if v & 2 else 0) | (TDI if v & 1 else 0)
                    if TDI_EARLY and (pins & TCK) and not (new & TCK):
                        # move TDI while TCK is still high (after the rising edge that used it)
                        pending.append((pins & ~TDI) | (new & TDI))
                    pins = new
                    pending.append(pins)
                elif ch == 'R':
                    # the sample of the next written byte is the pins' state now
                    pending.append(pins); reads.append(len(pending) - 1)
                elif ch == 'Q':
                    resp += flush(); c.sendall(resp); return False
                # 'B'/'b' blink, 'r'..'u' resets: ignored (no SRST/TRST wired)
            if reads or len(pending) > 4096:
                resp += flush()
            if resp:
                c.sendall(resp)
    finally:
        flush(); c.close()
    return True

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--serial', default='120001')
    ap.add_argument('--idcode', action='store_true')
    ap.add_argument('--server', type=int)
    ap.add_argument('--tdi-early', action='store_true',
                    help='change TDI while TCK is high, before the falling edge (JTDI test)')
    a = ap.parse_args()
    TDI_EARLY = a.tdi_early
    f = Ftdi(a.serial)
    try:
        if a.idcode:
            print(f'idcode 0x{idcode(f):08x}')
        if a.server:
            server(f, a.server)
    finally:
        f.close()
