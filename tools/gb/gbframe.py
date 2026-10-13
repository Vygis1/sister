"""Frames in and out of the Game Boy bench.

    python tools/gb/gbframe.py ref  img/reference-dmg.png  sim/roms/gb/acid2_ref.hex
        the reference PNG as 160x144 shades (0 lightest .. 3 darkest), one per
        line, for tb_gb's REF plusarg to compare against in the run

    python tools/gb/gbframe.py cmp  build/sim-tb_gb/frame.ppm  img/reference-dmg.png
        compare a dumped frame with a reference PNG; exit 1 on any difference

    python tools/gb/gbframe.py png  build/sim-tb_gb/frame.ppm  build/frame.png
        the dumped frame as a PNG, to look at

dmg-acid2 asks for the greys $FF, $AA, $55, $00 for shades 0..3; the bench's PPM
uses the same so the two can be compared byte for byte.
"""
import sys

from PIL import Image

GREYS = [0xFF, 0xAA, 0x55, 0x00]


def shade(g):
    return GREYS.index(g) if g in GREYS else min(range(4), key=lambda s: abs(GREYS[s] - g))


def load_png(path):
    im = Image.open(path).convert('L')
    if im.size != (160, 144):
        sys.exit('%s is %dx%d, not 160x144' % (path, im.size[0], im.size[1]))
    return [shade(g) for g in im.get_flattened_data()] if hasattr(im, 'get_flattened_data') else [shade(g) for g in im.getdata()]


def load_ppm(path):
    d = open(path, 'rb').read()
    # P6, then width height maxval, each separated by one whitespace
    parts = d.split(None, 4)
    assert parts[0] == b'P6' and parts[1] == b'160' and parts[2] == b'144', 'not a 160x144 P6'
    px = parts[4][-160 * 144 * 3:]
    return [shade(px[3 * i]) for i in range(160 * 144)]


def main():
    cmd = sys.argv[1]
    if cmd == 'ref':
        ref = load_png(sys.argv[2])
        with open(sys.argv[3], 'w') as f:
            for s in ref:
                f.write('%x\n' % s)
        print('%s: %d shades' % (sys.argv[3], len(ref)))
    elif cmd == 'cmp':
        got, ref = load_ppm(sys.argv[2]), load_png(sys.argv[3])
        bad = [i for i in range(160 * 144) if got[i] != ref[i]]
        print('%d of %d pixels differ' % (len(bad), 160 * 144))
        for i in bad[:20]:
            print('  (%d,%d): got %d want %d' % (i % 160, i // 160, got[i], ref[i]))
        if bad:
            rows = sorted(set(i // 160 for i in bad))
            print('  rows with differences: %s' % rows)
            sys.exit(1)
    elif cmd == 'png':
        got = load_ppm(sys.argv[2])
        im = Image.new('L', (160, 144))
        im.putdata([GREYS[s] for s in got])
        im.save(sys.argv[3])
        print(sys.argv[3])
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
