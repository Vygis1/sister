"""pcgrab.py - the PC core's screen as a picture: asks the ESP32 for "pcgrab" (through pad.py's tool
port) and puts its rows back together out of pad.py's log (build/pad.log).
    python tools/pc/pcgrab.py [out.png]          (default build/pc/grab.png)"""
import base64
import os
import socket
import sys
import time

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LOG = os.path.join(ROOT, 'build', 'pad.log')


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'build', 'pc', 'grab.png')
    start = os.path.getsize(LOG)
    s = socket.create_connection(('127.0.0.1', 5557), timeout=5)
    s.sendall(b'S pcgrab\n')
    s.close()
    t0 = time.time()
    while time.time() - t0 < 60:
        with open(LOG, 'rb') as f:
            f.seek(start)
            text = f.read().replace(b'\x00', b'').decode(errors='replace')
        if 'G end' in text:
            break
        time.sleep(0.5)
    else:
        sys.exit('no "G end" in the log within 60 s')
    w = h = 0
    rows = {}
    for line in text.splitlines():
        if line.startswith('G ') and line != 'G end' and not w:
            w, h = (int(v) for v in line.split()[1:3])
        elif line.startswith('G') and line[1:2].isdigit():
            y, b = line[1:].split(' ', 1)
            rows[int(y)] = base64.b64decode(b.strip())
    if rows and (not w or not h):         # (the size line can be mixed into another thread's print)
        h = max(rows) + 1
        w = max(len(d) for d in rows.values()) // 2
    if not w or not h:
        sys.exit('no picture size (the PC not running?)')
    im = Image.new('RGB', (w, h))
    px = im.load()
    for y, d in rows.items():
        for x in range(min(w, len(d) // 2)):
            v = d[2 * x] | (d[2 * x + 1] << 8)
            px[x, y] = ((v >> 11) << 3, ((v >> 5) & 63) << 2, (v & 31) << 3)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    im.save(out)
    print('%s: %d x %d, %d rows in %.1f s' % (out, w, h, len(rows), time.time() - t0))


if __name__ == '__main__':
    main()
