"""The PC Engine bench's frame as a PNG, to look at.

    python tools/pce/pceframe.py build/sim-tb_pce/frame.ppm build/pce_frame.png [SCALE]
"""
import sys

from PIL import Image


def main():
    src, dst = sys.argv[1], sys.argv[2]
    scale = int(sys.argv[3]) if len(sys.argv) > 3 else 2
    im = Image.open(src)
    im = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
    im.save(dst)
    print('%s: %d x %d' % (dst, im.width, im.height))


if __name__ == '__main__':
    main()
