"""fbgrab.py - the N64's framebuffer as the VI shows it, off the board (through tools/pad.py's
tool port and console_top's DDR3 line read, 0x7C/0x80), and what n64_vid's filters make of it.

    python tools/n64/fbgrab.py [OUT] [--jtag] [--live]   -> OUT.raw (the 16-bit frame) + OUT_<mode>.png

--jtag reads over the JTAG cable (a JTAG=1 debug build, tools/jtag.py) instead of tools/pad.py's tool
port; --live leaves the game running (the frame may change under the read: pause the game first).

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
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..', '..')
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import vidref     # noqa: E402

NES = 0x00080000
_f = None


_j = None
JTAG = '--jtag' in sys.argv
LIVE = '--live' in sys.argv
# --freeze: n64_top's FREEZE (dbg_sel[7], images from 2026-10-11): the memory port serves only the
# picture and these reads while the frame is read, so nothing draws over it; the game then carries on
FREEZE = '--freeze' in sys.argv
sys.argv = [a for a in sys.argv if a not in ('--jtag', '--live', '--freeze')]


def q(cmd):
    global _f
    if _f is None:
        _f = socket.create_connection(('127.0.0.1', 5557), timeout=10).makefile('rwb')
    _f.write(cmd.encode() + b'\n'); _f.flush()
    return _f.readline().decode().strip()


def _jt():
    global _j
    if _j is None:
        sys.path.insert(0, os.path.join(ROOT, 'tools'))
        from jtag import Jtag
        _j = Jtag()
    return _j


def rd(a):
    if JTAG:
        return _jt().read(a)
    return int(q('R %08x' % a).split()[-1], 16)


def wr(a, v):
    if JTAG:
        _jt().write(a, v)
        return
    q('W %08x %x' % (a, v))


def line(n):
    wr(NES + 0x7C, n)
    for _ in range(50):
        if rd(NES + 0x7C) >> 31:
            break
    w = [rd(NES + 0x80 + 4 * k) for k in range(4)]
    return b''.join(struct.pack('<I', x) for x in w)       # byte k of the line at bits 8k+7:8k


def jtag_lines(first, n):
    """n DDR3 lines from `first`, as 16-byte strings, in ONE Vivado call: the loop runs in Tcl (a
    write of the line number, a 4-word burst read of the answer), not a JTAG round trip a word"""
    j = _jt()
    out = j.tcl('set R {}; for {set i 0} {$i < %d} {incr i} { '
                'create_hw_axi_txn -force w $A -type write -address %08x -len 1 -data [format %%08x [expr {%d + $i}]]; '
                'run_hw_axi -quiet [get_hw_axi_txns w]; '
                'create_hw_axi_txn -force r $A -type read -address %08x -len 4; '
                'run_hw_axi -quiet [get_hw_axi_txns r]; '
                'lappend R [get_property DATA [get_hw_axi_txns r]] }; puts "lines=$R"'
                % (n, NES + 0x7C, first, NES + 0x80))
    vals = [l for l in out.splitlines() if l.startswith('lines=')][-1][6:].split()
    res = []
    for v in vals:
        v = v.rjust(32, '0')
        beats = [int(v[8 * i:8 * i + 8], 16) for i in range(4)][::-1]      # the last beat first
        res.append(b''.join(struct.pack('<I', x) for x in beats))
    return res


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
    if FREEZE:                                                    # (frozen first: the origin read is then the frame kept)
        sel0 = rd(NES + 0x170)
        wr(NES + 0x170, sel0 | 0x80)
        time.sleep(0.05)
    vist, origin, width = rd(NES + 0x150), rd(NES + 0x154), rd(NES + 0x158)
    print('VI_STATUS %05x, origin %06x, width %d' % (vist, origin, width))
    if (vist & 3) != 2 or width != 320:
        print('(only a 16-bit 320-wide frame is handled here)')
        if FREEZE:
            wr(NES + 0x170, sel0 & ~0x80)
        return
    ctrl = rd(NES + 0x04)
    sel = rd(NES + 0x170) & ~0x80 if FREEZE else 0
    if FREEZE:
        pass                                                      # (frozen above: everything but the picture waits)
    elif not LIVE:
        wr(NES + 0x04, ctrl & ~1)                                 # stop (the frame stays in DDR3)
    try:
        words = []
        base = (origin & 0xFFFFFF) >> 4
        for y in range(240):
            if JTAG:
                words.append([int.from_bytes(l, 'little') for l in jtag_lines(base + y * 40, 40)])
            else:
                words.append([int.from_bytes(line(base + y * 40 + k), 'little') for k in range(40)])
            if y % 40 == 0:
                print('  row %d' % y)
    finally:
        if FREEZE:
            wr(NES + 0x170, sel & ~0x80)                           # and the game carries on
        elif not LIVE:
            wr(NES + 0x04, ctrl)                                   # and the game boots again
    open(out + '.raw', 'wb').write(b''.join(w.to_bytes(16, 'little') for row in words for w in row))
    vidref.source_words = lambda case: words
    for name, opt in (('sharp', 0x91), ('vi', 0x80), ('smooth', 0x82), ('edge', 0x83)):
        vidref.CASES['grab_' + name] = (0, 320, 240, 0, 0, opt, vist & 0x1FFFF)
        png('%s_%s.png' % (out, name), vidref.model('grab_' + name))
        print(out + '_' + name + '.png')


if __name__ == '__main__':
    main()
