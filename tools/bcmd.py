"""bcmd.py - a command to the console's ESP32 (through tools/pad.py's tool port) and its answer.

    python tools/bcmd.py "ls /roms/gb"              the answer (the lines the ESP32 printed after it)
    python tools/bcmd.py "play /roms/nes/x.nes" 20  waiting up to 20 s for the answer
    python tools/bcmd.py -r 10 14                   console registers (hex offsets): their values
    python tools/bcmd.py -w 14 B0070000             a register written

The serial console's own commands: see esp32/console/console.ino (serviceSerial)."""
import os
import re
import socket
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOG = os.path.join(ROOT, 'build', 'pad.log')
NOISE = ('Traceback', 'File "', 'self.', 'for raw', 'Exception in thread', 'Connection', 'return self', '^^^')


def sock():
    return socket.create_connection(('127.0.0.1', 5557), timeout=5)


def command(line, wait=3.0):
    start = os.path.getsize(LOG)
    s = sock()
    s.sendall(('S ' + line + '\n').encode())
    s.close()
    t0 = time.time()
    out = []
    last = start
    quiet = time.time()
    while time.time() - t0 < wait:
        time.sleep(0.2)
        size = os.path.getsize(LOG)
        if size != last:
            last = size; quiet = time.time()
            with open(LOG, 'rb') as f:
                f.seek(start)
                got = f.read().replace(bytes([0]), b'')
            # (a command's own answer line: done -- "play:" after a load, else anything once it goes quiet)
            if line.startswith('play ') and b'  play:' in got:
                break
        elif last != start and not line.startswith('play ') and time.time() - quiet > 1.0:
            break
    with open(LOG, 'rb') as f:
        f.seek(start)
        text = f.read().replace(b'\x00', b'').decode(errors='replace')
    for l in text.splitlines():
        if l.strip() and not any(n in l for n in NOISE):
            out.append(l)
    return out


def regs(offs, write=None):
    s = sock()
    s.settimeout(1.0)
    res = []
    if write is not None:
        s.sendall(('W %x %x\n' % (offs[0], write)).encode())
        time.sleep(0.3)
        try:
            s.recv(4096)
        except socket.timeout:
            pass
        return []
    for o in offs:
        s.sendall(('R %x\n' % o).encode())
        time.sleep(0.25)
        try:
            d = s.recv(4096).decode(errors='replace')
        except socket.timeout:
            d = ''
        m = re.findall(r'[0-9a-fA-F]{8}', d)
        res.append(int(m[-1], 16) if m else None)
    s.close()
    return res


if __name__ == '__main__':
    a = sys.argv[1:]
    if not a:
        sys.exit(__doc__)
    if a[0] == '-r':
        offs = [int(x, 16) for x in a[1:]]
        for o, v in zip(offs, regs(offs)):
            print('%04X: %s' % (o, '%08X' % v if v is not None else '?'))
    elif a[0] == '-w':
        regs([int(a[1], 16)], int(a[2], 16))
    else:
        for l in command(a[0], float(a[1]) if len(a) > 1 else 3.0):
            print(l)
