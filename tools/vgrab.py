"""vgrab.py - the picture a console core is sending to the TV, as a PNG: asks the ESP32 for "vgrab"
(through tools/pad.py's tool port), which reads console_top's line grabber (rtl/line_grab.v) a line at a
time, and puts the rows back together out of pad.py's log. A still picture comes out whole; a moving
one is a line from each of 480 frames. Not in the PlayStation or N64 images (their chips are full).

    python tools/vgrab.py [out.png] [step]      (default build/vgrab.png, every line)
"""
import base64
import os
import socket
import sys
import time

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOG = os.path.join(ROOT, 'build', 'pad.log')


def grab(out, step=1, timeout=180):
    start = os.path.getsize(LOG)
    s = socket.create_connection(('127.0.0.1', 5557), timeout=5)
    s.sendall(('S vgrab %d\n' % step).encode())
    s.close()
    t0 = time.time()
    while time.time() - t0 < timeout:
        with open(LOG, 'rb') as f:
            f.seek(start)
            text = f.read().replace(b'\x00', b'').decode(errors='replace')
        if 'V end' in text:
            break
        time.sleep(0.5)
    else:
        raise RuntimeError('no "V end" in the log within %d s' % timeout)
    if 'V no line' in text:
        raise RuntimeError(next(l for l in text.splitlines() if 'V no line' in l).strip())
    rows = {}
    for line in text.splitlines():
        if line.startswith('V') and line[1:2].isdigit():
            y, b = line[1:].split(' ', 1)
            try:
                rows[int(y)] = base64.b64decode(b.strip())
            except Exception:
                pass                          # (a line broken by another thread's print)
    img = Image.new('RGB', (640, 480))
    px = img.load()
    for y in range(480):
        src = rows.get(y - y % step)
        if not src or len(src) < 1280:
            continue
        for x in range(640):
            v = src[2 * x] | (src[2 * x + 1] << 8)
            r, g, b = (v >> 11) & 31, (v >> 5) & 63, v & 31
            px[x, y] = (r << 3 | r >> 2, g << 2 | g >> 4, b << 3 | b >> 2)
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    img.save(out)
    return len(rows)


if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'build', 'vgrab.png')
    step = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    n = grab(out, step)
    print('%s: %d lines' % (out, n))
