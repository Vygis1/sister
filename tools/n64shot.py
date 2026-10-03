"""The picture the board is showing, from the server's frame stream
(/api/vid/frame: RGB555, its size in X-Width / X-Height), as a PNG.

    python tools/n64shot.py OUT.png [--count N --every SECONDS]
"""
import os
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import n64model  # noqa: E402  (write_png)

SERVER = 'http://127.0.0.1:8080'


def shot(path):
    r = urllib.request.urlopen(SERVER + '/api/vid/frame', timeout=20)
    data = r.read()
    w, h = int(r.headers.get('X-Width', 320)), int(r.headers.get('X-Height', 240))
    fmt = r.headers.get('X-Format', '')
    rgb = bytearray()
    for i in range(w * h):
        v = data[2 * i] | (data[2 * i + 1] << 8) if 2 * i + 1 < len(data) else 0
        r5, g5, b5 = v & 31, (v >> 5) & 31, (v >> 10) & 31
        rgb += bytes(((r5 << 3) | (r5 >> 2), (g5 << 3) | (g5 >> 2), (b5 << 3) | (b5 >> 2)))
    n64model.write_png(path, w, h, bytes(rgb))
    return w, h, fmt, len(data)


if __name__ == '__main__':
    out = sys.argv[1]
    n = int(sys.argv[sys.argv.index('--count') + 1]) if '--count' in sys.argv else 1
    every = float(sys.argv[sys.argv.index('--every') + 1]) if '--every' in sys.argv else 5
    for k in range(n):
        p = out if n == 1 else out.replace('.png', '_%02d.png' % k)
        print(p, shot(p))
        if k + 1 < n:
            time.sleep(every)
