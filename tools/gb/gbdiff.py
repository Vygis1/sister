"""Side by side, as text: a dumped frame against a reference PNG, for the rows asked.

    python tools/gb/gbdiff.py build/sim-gb-acid2/frame.ppm build/dmg-acid2/img/reference-dmg.png 0 8 [x0 x1]

Shades print as ' ', '.', '+', '#'; the third block is the difference ('X').
"""
import sys

sys.path.insert(0, 'tools/gb')
from gbframe import load_png, load_ppm  # noqa: E402

CH = ' .+#'


def main():
    got, ref = load_ppm(sys.argv[1]), load_png(sys.argv[2])
    y0, y1 = int(sys.argv[3]), int(sys.argv[4])
    x0 = int(sys.argv[5]) if len(sys.argv) > 5 else 0
    x1 = int(sys.argv[6]) if len(sys.argv) > 6 else 160
    for y in range(y0, y1):
        g = ''.join(CH[got[y * 160 + x]] for x in range(x0, x1))
        r = ''.join(CH[ref[y * 160 + x]] for x in range(x0, x1))
        d = ''.join('X' if got[y * 160 + x] != ref[y * 160 + x] else ' ' for x in range(x0, x1))
        print('%3d |%s| |%s| |%s|' % (y, g, r, d))


if __name__ == '__main__':
    main()
