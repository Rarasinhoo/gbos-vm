#!/usr/bin/env python3
"""Checks the viewer's Bluetooth relay (host/bluetooth.m) from the VM's side of the radio.

  python3 tests/bluetooth_relay.py WORK/logs/RUN_NAME [NAME]

With the VM running with Bluetooth on, this joins its virtual radio as one more controller,
the way Android's own does, and lists the twins the relay advertises. Given NAME, it connects
to the one whose name contains it, which should be a device of yours, and walks its GATT
database: services, characteristics, and the value of every readable one. It only reads."""
import socket, struct, sys, time
from pathlib import Path


class HCI:
    def __init__(self, port):
        self.s = socket.create_connection(('127.0.0.1', port)); self.buf = b''; self.events = []

    def _packet(self, timeout):
        self.s.settimeout(timeout)
        while True:
            if len(self.buf) >= 3 and self.buf[0] == 4 and len(self.buf) >= 3 + self.buf[2]:
                p, self.buf = self.buf[:3 + self.buf[2]], self.buf[3 + self.buf[2]:]; return p
            if len(self.buf) >= 5 and self.buf[0] == 2 and len(self.buf) >= 5 + struct.unpack('<H', self.buf[3:5])[0]:
                n = 5 + struct.unpack('<H', self.buf[3:5])[0]; p, self.buf = self.buf[:n], self.buf[n:]; return p
            try: chunk = self.s.recv(65536)
            except socket.timeout: return None
            if not chunk: raise EOFError
            self.buf += chunk

    def cmd(self, op, params=b''):
        self.s.sendall(bytes([1]) + struct.pack('<HB', op, len(params)) + params)
        while True:
            p = self._packet(5)
            if p is None: raise TimeoutError(hex(op))
            if p[0] == 4 and p[1] == 0x0e and struct.unpack('<H', p[4:6])[0] == op: return p[6:]
            if p[0] == 4 and p[1] == 0x0f and struct.unpack('<H', p[5:7])[0] == op: return p[3:4]
            self.events.append(p)

    def next(self, timeout):
        if self.events: return self.events.pop(0)
        return self._packet(timeout)


def ad_fields(data):
    i, out = 0, {}
    while i < len(data) and data[i]:
        n = data[i]; out.setdefault(data[i + 1], []).append(data[i + 2:i + 1 + n]); i += 1 + n
    return out


def main():
    run = Path(sys.argv[1]); want = sys.argv[2].lower() if len(sys.argv) > 2 else None
    h = HCI(int((run / 'bluetooth-port').read_text()))
    h.cmd(0x0c03); h.cmd(0x0c01, bytes.fromhex('ffffffffffffbf3d')); h.cmd(0x2001, bytes.fromhex('1f0a000000000000'))
    h.cmd(0x200b, struct.pack('<BHHBB', 1, 0x30, 0x30, 0, 0)); h.cmd(0x200c, b'\1\0')
    seen, end = {}, time.time() + 6
    while time.time() < end:
        p = h.next(0.5)
        if not p or p[0] != 4 or p[1] != 0x3e or p[3] != 2: continue
        n, q = p[4], 5
        for _ in range(n):
            evt, atype, addr, ln = p[q], p[q + 1], p[q + 2:q + 8], p[q + 8]
            data = p[q + 9:q + 9 + ln]; q += 10 + ln
            d = seen.setdefault(addr, {'type': atype, 'connectable': False, 'name': ''})
            d['connectable'] |= evt in (0, 1)
            f = ad_fields(data)
            if 9 in f or 8 in f: d['name'] = (f.get(9) or f.get(8))[0].decode(errors='replace')
    h.cmd(0x200c, b'\0\0')
    print(f'{len(seen)} devices on the virtual radio')
    for a, d in seen.items():
        print(f"  {a[::-1].hex(':')}  {'connectable' if d['connectable'] else 'broadcast  '}  {d['name']}")
    if not want: return 0 if seen else 1
    pick = [a for a, d in seen.items() if d['connectable'] and want in d['name'].lower()]
    if not pick: print('no connectable device named', want); return 1
    addr = pick[0]; print('\nconnecting to', seen[addr]['name'])
    h.cmd(0x200d, struct.pack('<HHBB6sBHHHHHH', 0x60, 0x30, 0, seen[addr]['type'], addr, 0, 0x18, 0x28, 0, 400, 0, 0))
    conn = None
    while conn is None:
        p = h.next(15)
        if p is None: print('no connection'); return 1
        if p[0] == 4 and p[1] == 0x3e and p[3] in (1, 10):
            if p[4]: print('connection failed', hex(p[4])); return 1
            conn = struct.unpack('<H', p[5:7])[0]

    def att(req, timeout=20):
        l2 = struct.pack('<HH', len(req), 4) + req
        h.s.sendall(bytes([2]) + struct.pack('<HH', conn, len(l2)) + l2)
        data, want_len = b'', None
        while True:
            p = h.next(timeout)
            if p is None: raise TimeoutError('ATT')
            if p[0] != 2: continue
            payload = p[5:]
            if want_len is None:
                want_len = struct.unpack('<H', payload[:2])[0]
                if struct.unpack('<H', payload[2:4])[0] != 4: want_len = None; continue
                data = payload[4:]
            else: data += payload
            if len(data) >= want_len:
                if data[0] in (0x1b, 0x1d): want_len = None; continue   # notifications in between
                return data

    print('MTU', struct.unpack('<H', att(b'\x02\xf7\x00')[1:3])[0])
    services, start = [], 1
    while start <= 0xffff:
        r = att(struct.pack('<BHHH', 0x10, start, 0xffff, 0x2800))
        if r[0] == 1: break
        ln = r[1]
        for i in range(2, len(r), ln):
            s, e = struct.unpack('<HH', r[i:i + 4]); services.append((s, e, r[i + 4:i + ln][::-1].hex()))
        start = services[-1][1] + 1
    for s, e, u in services:
        print(f'service {u}  handles {s}-{e}')
        start = s
        while start <= e:
            r = att(struct.pack('<BHHH', 0x08, start, e, 0x2803))
            if r[0] == 1: break
            ln = r[1]
            for i in range(2, len(r), ln):
                decl, props, vh = struct.unpack('<HBH', r[i:i + 5]); uuid = r[i + 5:i + ln][::-1].hex()
                value = ''
                if props & 0x02:
                    v = att(struct.pack('<BH', 0x0a, vh))
                    value = f'= {v[1:].hex()} {v[1:].decode(errors="replace")!r}' if v[0] == 0x0b else f'(read error {v[4]:#x})'
                print(f'  characteristic {uuid}  props {props:#04x}  handle {vh}  {value}')
                start = vh + 1
    h.cmd(0x0406, struct.pack('<HB', conn, 0x13))
    return 0


if __name__ == '__main__':
    sys.exit(main())
