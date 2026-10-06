"""fbmodel.py - a game's frame out of the model (tools/n64/n64model.py, the RDP drawing in
tools/n64/n64rdp.py) WITH its hidden coverage bits, and n64_vid's VI filters run on it twice:
with the true coverage, and with the guess the board makes without the hidden bits
({alpha, 1, 1}). What the guess costs, on a real picture.

    python tools/n64/fbmodel.py ROM SECONDS [OUT]     -> OUT.raw, OUT.hid, OUT_{raw,true,guess}.png
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..', '..')
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import n64model       # noqa: E402
import n64rdptests    # noqa: E402
import vidref         # noqa: E402
from fbgrab import png   # noqa: E402


def main():
    rom_path, secs = sys.argv[1], float(sys.argv[2])
    out = sys.argv[3] if len(sys.argv) > 3 else os.path.join(ROOT, 'build', 'fbmodel')
    rom = open(rom_path, 'rb').read()
    m = n64model.N64(rom)
    n64rdptests.ensure_rdp(m)
    m.fast_boot()
    c = m.cpu
    t0 = time.time()
    target = int(secs * 60)
    while m.vi_frames < target:
        for _ in range(4096):
            c.step()
    print('frame %d after %.0f s' % (m.vi_frames, time.time() - t0))
    status, origin, width = m.vi[0], m.vi[1] & 0xFFFFFF, m.vi[2] & 0xFFF
    print('VI_STATUS %05x origin %06x width %d' % (status, origin, width))
    rd, hid = m.rdram, m.rdp.hidden
    words = []
    for y in range(240):
        row = []
        for k in range(40):
            v = 0; h = 0
            for i in range(8):
                a = origin + 2 * (y * width + 8 * k + i)
                v |= rd[a] << (16 * i) | rd[a + 1] << (16 * i + 8)
                h |= hid[a >> 1] << (2 * i)
            row.append(v | h << 128)
        words.append(row)
    open(out + '.raw', 'wb').write(bytes(rd[origin:origin + 2 * width * 240]))
    open(out + '.hid', 'wb').write(bytes(hid[origin >> 1:(origin >> 1) + width * 240]))
    vidref.source_words = lambda case: words
    for name, opt, hok in (('raw', 0x91, 0), ('true', 0x80, 1), ('guess', 0x80, 0)):
        vidref.CASES['fbm_' + name] = (0, 320, 240, 0, hok, opt, status & 0x1FFFF)
        png('%s_%s.png' % (out, name), vidref.model('fbm_' + name))
        print('%s_%s.png' % (out, name))


if __name__ == '__main__':
    main()
