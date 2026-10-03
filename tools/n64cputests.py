"""krom's CPU test ROMs through the Python model: PASS and FAIL counted off the screen.

    python tools/n64cputests.py [sim/roms/n64/krom] [--only NAME]

Each ROM prints a row per case into a 640x480 32-bit framebuffer, with the
word PASS in green or FAIL in red in the right-hand column. This runs each one
in tools/n64model.py, writes its screen to build/n64tests/NAME.png, and counts
the rows by colour: a run of green or red pixels in that column is one row.
"""
import glob
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import n64model  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', 'build', 'n64tests')


def score(w, h, rgb):
    """PASS and FAIL rows: in each band of text, the rightmost coloured box --
    if it is four characters wide (a PASS or FAIL box; headers and labels are
    wider) -- green for PASS, red for FAIL"""
    def kind(x, y):
        p = (y * w + x) * 3
        R, G, B = rgb[p], rgb[p + 1], rgb[p + 2]
        if G >= 100 and R < 60 and B < 60: return 'g'
        if R >= 100 and G < 60 and B < 60: return 'r'
        if R > 150 and G > 150 and B > 150: return 'w'
        return None
    passes = fails = 0
    y = 0
    while y < h:
        if not any(kind(x, y) in ('g', 'r') for x in range(0, w, 2)):
            y += 1
            continue
        top = y
        while y < h and any(kind(x, y) in ('g', 'r') for x in range(0, w, 2)):
            y += 1
        mid = (top + y) // 2
        # the rightmost coloured pixel, and the box it belongs to
        x = w - 1
        while x >= 0 and kind(x, mid) not in ('g', 'r'):
            x -= 1
        if x < 0:
            continue
        colour, right, gap = kind(x, mid), x, 0
        while x >= 0 and gap <= 2:
            gap = gap + 1 if kind(x, mid) is None else 0
            x -= 1
        width = right - x - gap
        if 24 <= width <= 44:
            if colour == 'g': passes += 1
            else: fails += 1
    return passes, fails


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith('--') else \
        os.path.join(HERE, '..', 'sim', 'roms', 'n64', 'krom')
    only = sys.argv[sys.argv.index('--only') + 1] if '--only' in sys.argv else None
    os.makedirs(OUT, exist_ok=True)
    roms = sorted(glob.glob(os.path.join(root, 'CPUTest', '**', '*.N64'), recursive=True))
    roms += sorted(glob.glob(os.path.join(root, 'RSPTest', '**', '*.N64'), recursive=True))
    total_p = total_f = 0
    for path in roms:
        name = os.path.splitext(os.path.basename(path))[0]
        if only and only.lower() not in name.lower():
            continue
        m = n64model.N64(open(path, 'rb').read())
        m.fast_boot()
        t0 = time.time()
        err = ''
        try:
            n64model.run(m, 8_000_000)
        except Exception as e:
            err = '%s: %s' % (type(e).__name__, e)
        w, h, rgb = m.framebuffer()
        p = f = 0
        if w:
            n64model.write_png(os.path.join(OUT, name + '.png'), w, h, rgb)
            p, f = score(w, h, rgb)
        total_p += p; total_f += f
        print('%-22s %3d pass %3d fail  %9d instr %5.0f s  %s' % (name, p, f, m.cpu.instructions, time.time() - t0, err or ('' if w else 'no picture')))
        sys.stdout.flush()
    print('total: %d pass, %d fail' % (total_p, total_f))


if __name__ == '__main__':
    main()
