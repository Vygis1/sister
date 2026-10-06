"""fbgrab.py - the N64's framebuffer as the VI shows it, off the board (through pc/pad.py's
tool port and console_top's DDR3 line read, 0x7C/0x80), and what n64_vid's filters make of it.

    python tools/n64/fbgrab.py [OUT]       -> OUT.raw (the 16-bit frame) + OUT_<mode>.png

The N64 does not pause (NES_CTRL bit 2 stops the other consoles, not this one), and a
320 x 240 frame is 9,600 lines, about three minutes -- the game would draw over it many
times. So the N64 is STOPPED (NES_CTRL run = 0: held in reset; RDRAM, in DDR3, keeps the
frame the VI was showing) and started again afterwards: the game boots again from the
cartridge, still in memory. Not while someone is playing.
The pictures are tools/vidref.py's model run on the frame (the RTL is that model, bit for
bit -- tools/vidref.py all): sharp, the VI as the game asks, smooth, edge-directed.
"""
import os
import socket
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..', '..')
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import vidref     # noqa: E402

NES = 0x00080000
_f = None


def q(cmd):
    global _f
    if _f is None:
        _f = socket.create_connection(('127.0.0.1', 5557), timeout=10).makefile('rwb')
    _f.write(cmd.encode() + b'\n'); _f.flush()
    return _f.readline().decode().strip()


def rd(a):
    return int(q('R %08x' % a).split()[-1], 16)


def wr(a, v):
    q('W %08x %x' % (a, v))


def line(n):
    wr(NES + 0x7C, n)
    for _ in range(50):
        if rd(NES + 0x7C) >> 31:
            break
    w = [rd(NES + 0x80 + 4 * k) for k in range(4)]
    return b''.join(struct.pack('<I', x) for x in w)       # byte k of the line at bits 8k+7:8k


def png(path, img):
    h, w = len(img), len(img[0])
    raw = b''.join(b'\0' + bytes(c for px in row for c in px) for row in img)

    def chunk(t, d):
        c = struct.pack('>I', len(d)) + t + d
        return c + struct.pack('>I', zlib.crc32(t + d) & 0xFFFFFFFF)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
                           chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'build', 'sm64')
    vist, origin, width = rd(NES + 0x150), rd(NES + 0x154), rd(NES + 0x158)
    print('VI_STATUS %05x, origin %06x, width %d' % (vist, origin, width))
    if (vist & 3) != 2 or width != 320:
        print('(only a 16-bit 320-wide frame is handled here)')
        return
    ctrl = rd(NES + 0x04)
    wr(NES + 0x04, ctrl & ~1)                                     # stop (the frame stays in DDR3)
    try:
        words = []
        base = (origin & 0xFFFFFF) >> 4
        for y in range(240):
            words.append([int.from_bytes(line(base + y * 40 + k), 'little') for k in range(40)])
            if y % 40 == 0:
                print('  row %d' % y)
    finally:
        wr(NES + 0x04, ctrl)                                       # and the game boots again
    open(out + '.raw', 'wb').write(b''.join(w.to_bytes(16, 'little') for row in words for w in row))
    vidref.source_words = lambda case: words
    for name, opt in (('sharp', 0x91), ('vi', 0x80), ('smooth', 0x82), ('edge', 0x83)):
        vidref.CASES['grab_' + name] = (0, 320, 240, 0, 0, opt, vist & 0x1FFFF)
        png('%s_%s.png' % (out, name), vidref.model('grab_' + name))
        print(out + '_' + name + '.png')


if __name__ == '__main__':
    main()
