"""Our PC Engine frame against Mednafen's snapshot of the same game.

    python tools/pce/pcecmp.py build/sim-tb_pce/frame.ppm build/blox_ref.png [build/diff.png]

Mednafen's snapshot is the picture it shows (some lines of the window cropped), ours the
whole display window: the comparison slides one over the other by a few lines and columns
and reports the best match -- pixels differing, where they are -- and writes a picture of
the differences (red where ours differs) if asked. Colours are compared after both are
reduced to 3 bits a channel (the console's), so Mednafen's scaling of them does not count.
"""
import sys

from PIL import Image


def load(path):
    im = Image.open(path).convert('RGB')
    return [[tuple(c >> 5 for c in im.getpixel((x, y))) for x in range(im.width)] for y in range(im.height)]


def main():
    ours, ref = load(sys.argv[1]), load(sys.argv[2])
    best = None
    for dy in range(-8, 9):
        for dx in range(-4, 5):
            bad = 0; n = 0
            for y in range(len(ref)):
                oy = y + dy
                if oy < 0 or oy >= len(ours): continue
                row_o, row_r = ours[oy], ref[y]
                for x in range(len(row_r)):
                    ox = x + dx
                    if ox < 0 or ox >= len(row_o): continue
                    n += 1
                    if row_o[ox] != row_r[x]: bad += 1
            if n and (best is None or bad < best[0]): best = (bad, n, dx, dy)
    bad, n, dx, dy = best
    print('best offset dx %d dy %d: %d of %d pixels differ (%.2f%%)' % (dx, dy, bad, n, 100.0 * bad / n))
    if len(sys.argv) > 3:
        im = Image.new('RGB', (len(ref[0]), len(ref)))
        rows = sorted(set())
        for y in range(len(ref)):
            for x in range(len(ref[0])):
                oy, ox = y + dy, x + dx
                same = 0 <= oy < len(ours) and 0 <= ox < len(ours[0]) and ours[oy][ox] == ref[y][x]
                c = ref[y][x]
                im.putpixel((x, y), (255, 0, 0) if not same else (c[0] * 36 // 2 + 60, c[1] * 36 // 2 + 60, c[2] * 36 // 2 + 60))
        im = im.resize((im.width * 2, im.height * 2), Image.NEAREST)
        im.save(sys.argv[3])
        print(sys.argv[3])
    sys.exit(0 if bad == 0 else 1)


if __name__ == '__main__':
    main()
