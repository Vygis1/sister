"""The bench's frame (a P3 PPM, X pixels allowed) as a PNG.
    python tools/gba/gbaframe.py build/sim-gba/frame.ppm build/gba.png [scale]
"""
import sys
from PIL import Image


def main():
    toks = open(sys.argv[1], 'rb').read().split()
    assert toks[0] == b'P3'
    w, h = int(toks[1]), int(toks[2])
    vals = [0 if b'x' in t or b'X' in t else int(t) for t in toks[4:4 + w * h * 3]]
    im = Image.new('RGB', (w, h))
    im.putdata([tuple(vals[i:i + 3]) for i in range(0, len(vals), 3)])
    scale = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    if scale > 1:
        im = im.resize((w * scale, h * scale), Image.NEAREST)
    im.save(sys.argv[2])
    print('%s: %d x %d' % (sys.argv[2], w, h))


if __name__ == '__main__':
    main()
