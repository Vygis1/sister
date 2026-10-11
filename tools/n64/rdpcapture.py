"""rdpcapture.py - one frame of a game's RDP work taken off the board and replayed through the model
and the RTL: the board's picture, tools/n64/n64rdp.py's and rtl/n64_rdp2.v's, side by side.

    python tools/n64/rdpcapture.py grab NAME     the board (a JTAG debug image with FREEZE, n64_top
                                                 dbg_sel[7]): frozen at the end of a frame, the
                                                 command list START..END read, every texture range
                                                 it loads, and the colour image it drew
    python tools/n64/rdpcapture.py prep NAME     -> sim/n64d/ (the model drawn the same list)
    ./tools/sim.sh tb_n64_rdp
    python tools/n64/rdpcapture.py check NAME    -> build/rdpcap/NAME/{board,model,rtl}.png, and how
                                                 many pixels differ between them

Games whose RDP reads its commands from RDRAM (DPC_STATUS XBUS clear: Mario Kart 64's menus) leave
the whole frame's list in memory until the next frame is built over it; frozen, nothing moves.

The capture is game data: it stays in build/rdpcap/ (never in the tree). The replay starts from
black RDRAM with only the commands and the loaded textures in it and TMEM empty, so anything a
frame takes from an earlier one (a texture loaded last frame, a background not redrawn) shows as a
difference against the board, not between the model and the RTL.
"""
import json
import os
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..', '..')
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, 'tools'))
OUT = os.path.join(ROOT, 'sim', 'n64d')
N = 0x80000
RAM = 8 << 20


def capdir(name):
    d = os.path.join(ROOT, 'build', 'rdpcap', name)
    os.makedirs(d, exist_ok=True)
    return d


# --- the board ------------------------------------------------------------------------------------
class Board:
    def __init__(self):
        from jtag import Jtag
        self.j = Jtag()
        self.sel0 = self.j.read(N + 0x170) & ~0xFF

    def freeze(self, on):
        self.j.write(N + 0x170, self.sel0 | (0x80 if on else 0))

    def dp(self, k):
        """DPC register k (0 START, 1 END, 2 CURRENT, 3 STATUS) through the debug window"""
        self.j.write(N + 0x170, self.sel0 | 0x80 | (9 + k))
        return self.j.read(N + 0x174)

    def lines(self, first, n):
        """n RDRAM lines (16 bytes, in address order) from line `first`, in one Vivado call"""
        out = []
        while n > 0:
            k = min(n, 256)
            r = self.j.tcl('set R {}; for {set i 0} {$i < %d} {incr i} { '
                           'create_hw_axi_txn -force w $A -type write -address %08x -len 1 -data [format %%08x [expr {%d + $i}]]; '
                           'run_hw_axi -quiet [get_hw_axi_txns w]; '
                           'create_hw_axi_txn -force r $A -type read -address %08x -len 4; '
                           'run_hw_axi -quiet [get_hw_axi_txns r]; '
                           'lappend R [get_property DATA [get_hw_axi_txns r]] }; puts "lines=$R"'
                           % (k, N + 0x7C, first, N + 0x80))
            vals = [l for l in r.splitlines() if l.startswith('lines=')][-1][6:].split()
            for v in vals:
                v = v.rjust(32, '0')
                beats = [int(v[8 * i:8 * i + 8], 16) for i in range(4)][::-1]
                out.append(b''.join(struct.pack('<I', x) for x in beats))
            first += k
            n -= k
        return out

    def read(self, addr, n):
        a0, a1 = addr & ~15, (addr + n + 15) & ~15
        data = b''.join(self.lines(a0 >> 4, (a1 - a0) >> 4))
        return data[addr - a0:addr - a0 + n]


# --- the list ---------------------------------------------------------------------------------------
def parse(cmds):
    """the colour image and the RDRAM ranges the list's loads read: [(addr, bytes)]"""
    img = (0, 0, 0, 0)                      # fmt, size, width, addr
    ranges, color, drawn = [], None, {}
    i = 0
    while i + 8 <= len(cmds):
        w0, w1 = struct.unpack('>II', cmds[i:i + 8])
        op = (w0 >> 24) & 0x3F
        # (a command's length in doublewords: triangles carry their coefficients)
        i += 8 * ({0x08: 4, 0x09: 6, 0x0A: 12, 0x0B: 14, 0x0C: 12, 0x0D: 14, 0x0E: 20, 0x0F: 22,
                   0x24: 2, 0x25: 2}.get(op, 1))
        if 0x08 <= op <= 0x0F or op in (0x24, 0x25, 0x36):
            drawn[color] = drawn.get(color, 0) + 1
        if op == 0x3D:
            img = ((w0 >> 21) & 7, (w0 >> 19) & 3, (w0 & 0x3FF) + 1, w1 & 0xFFFFFF)
        elif op == 0x3F:
            color = ((w0 >> 21) & 7, (w0 >> 19) & 3, (w0 & 0x3FF) + 1, w1 & 0xFFFFFF)
        elif op in (0x30, 0x33, 0x34):
            sl, tl, sh, th = (w0 >> 12) & 0xFFF, w0 & 0xFFF, (w1 >> 12) & 0xFFF, w1 & 0xFFF
            _, size, width, addr = img
            bpp = (1, 2, 4, 8)[size]           # in half-bytes
            if op == 0x33:                      # LOAD_BLOCK: sh - sl + 1 texels in a line from (sl, tl)
                start = addr + (((width * tl) + sl) * bpp >> 1)
                ranges.append((start, ((sh - sl + 1) * bpp + 1 >> 1) + 16))
            else:                               # LOAD_TILE / LOAD_TLUT: rows tl..th of sl..sh (10.2)
                for row in range(tl >> 2, (th >> 2) + 1):
                    start = addr + (((width * row) + (sl >> 2)) * bpp >> 1)
                    ranges.append((start, (((sh >> 2) - (sl >> 2) + 1) * bpp + 1 >> 1) + 16))
    # merged, in lines
    lines = sorted({l for a, n in ranges for l in range((a & 0x7FFFFF) >> 4, ((a & 0x7FFFFF) + n + 15) >> 4)})
    spans, s = [], None
    for l in lines:
        if s and l == s[0] + s[1]:
            s[1] += 1
        else:
            if s:
                spans.append(tuple(s))
            s = [l, 1]
    if s:
        spans.append(tuple(s))
    # the picture: the colour image most of the drawing went to (a frame may clear its depth
    # buffer through the colour image first)
    color = max((k for k in drawn if k), key=lambda k: drawn[k], default=color)
    return color, spans


def grab(name):
    d = capdir(name)
    b = Board()
    # (a game that sends a frame in pieces through one buffer -- Super Mario 64 -- has its colour
    # image and modes only in the first: tried again until the list caught sets its colour image)
    for tries in range(400):
        b.freeze(True)
        time.sleep(0.01)
        st, cur, end = b.dp(3), b.dp(2), b.dp(1)
        # the list all done (CURRENT at END) and the pipe idle (STATUS bits 5/6: pipe, cmd busy)
        if cur == end and not (st & 0x60):
            start, end = b.dp(0) & 0xFFFFF8, b.dp(1) & 0xFFFFF8
            cmds = b.read(start, end - start)
            color, spans = parse(cmds)
            if color:
                break
        b.freeze(False)
        time.sleep(0.003 + 0.011 * (tries % 5))
    else:
        b.freeze(False)
        raise SystemExit('never caught the RDP idle at the end of a list that sets its colour image')
    try:
        print('frozen: DPC START %06x END %06x STATUS %08x (try %d)' % (start, end, st, tries))
        print('%d commands; colour image fmt %d size %d width %d at %06x; %d texture ranges, %d lines'
              % (len(cmds) // 8, color[0], color[1], color[2], color[3], len(spans), sum(n for _, n in spans)))
        tex = {}
        for l, n in spans:
            tex['%x' % l] = b''.join(b.lines(l, n)).hex()
        fbn = color[2] * 240 * (2 if color[1] == 2 else 4)
        fb = b.read(color[3], fbn)
    finally:
        b.freeze(False)
    open(os.path.join(d, 'cmds.bin'), 'wb').write(cmds)
    open(os.path.join(d, 'board_fb.bin'), 'wb').write(fb)
    json.dump({'start': start, 'end': end, 'color': color, 'tex': tex}, open(os.path.join(d, 'cap.json'), 'w'))
    png16(os.path.join(d, 'board.png'), fb, color[2])
    print(os.path.join(d, 'board.png'))


# --- the replay -----------------------------------------------------------------------------------
def png16(path, fb, width, height=240):
    import n64model
    rgb = bytearray()
    for y in range(height):
        for x in range(width):
            i = 2 * (y * width + x)
            p = (fb[i] << 8) | fb[i + 1] if i + 1 < len(fb) else 0
            r, g, b_ = (p >> 11) & 31, (p >> 6) & 31, (p >> 1) & 31
            rgb += bytes(((r << 3) | (r >> 2), (g << 3) | (g >> 2), (b_ << 3) | (b_ >> 2)))
    n64model.write_png(path, width, height, bytes(rgb))


def prep(name):
    import n64rdp
    import n64rdpsim
    d = capdir(name)
    cap = json.load(open(os.path.join(d, 'cap.json')))
    cmds = open(os.path.join(d, 'cmds.bin'), 'rb').read()
    rd = bytearray(RAM)
    for l, h in cap['tex'].items():
        a = int(l, 16) << 4
        data = bytes.fromhex(h)
        rd[a:a + len(data)] = data
    rd[cap['start']:cap['start'] + len(cmds)] = cmds

    class Bus:
        pass
    bus = Bus()
    bus.rdram = bytearray(rd)
    bus.dmem = bytearray(4096)
    bus.mi_intr = 0
    r = n64rdp.RDP(bus)
    r.hidden = n64rdpsim.ConstHidden(len(bus.rdram) >> 1)
    writes = [(3, 1 | 4 | 16), (0, cap['start']), (1, cap['end'])]
    t0 = time.time()
    for i, v in writes:
        r.reg_write(i, v)
    print('model: %d commands, %d pixels, %.0f s' % (r.commands, r.pixels, time.time() - t0))
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, 'rdram.hex'), 'w') as f:
        for a in range(0, RAM, 16):
            f.write(rd[a:a + 16][::-1].hex() + '\n')
    with open(os.path.join(OUT, 'tmem.hex'), 'w') as f:
        f.write('0000\n' * 2048)
    with open(os.path.join(OUT, 'writes.hex'), 'w') as f:
        f.write('%x\n' % len(writes))
        for i, v in writes:
            f.write('0 %x %08x\n' % (i, v))
    fmt, size, width, fb = cap['color']
    fbn = width * 240 * 2
    open(os.path.join(OUT, 'rdp_lines.txt'), 'w').write(' '.join('%x' % l for l in range(fb >> 4, (fb + fbn) >> 4)))
    open(os.path.join(OUT, 'after.bin'), 'wb').write(bytes(bus.rdram))
    open(os.path.join(OUT, 'vi.txt'), 'w').write('%x %x %x\n' % (0x3, fb, width))
    png16(os.path.join(d, 'model.png'), bus.rdram[fb:fb + fbn], width)
    print(os.path.join(d, 'model.png'))


def check(name):
    d = capdir(name)
    cap = json.load(open(os.path.join(d, 'cap.json')))
    fmt, size, width, fb = cap['color']
    fbn = width * 240 * 2
    model = open(os.path.join(OUT, 'after.bin'), 'rb').read()[fb:fb + fbn]
    start = bytearray()
    for l in open(os.path.join(OUT, 'rdram.hex')):
        start += bytes.fromhex(l.strip())[::-1]
    got = bytearray(start)
    for l in open(os.path.join(OUT, 'rtl_lines.hex')):
        a, v = l.split()
        a = int(a, 16) * 16
        got[a:a + 16] = bytes.fromhex(v)[::-1]
    rtl = bytes(got[fb:fb + fbn])
    board = open(os.path.join(d, 'board_fb.bin'), 'rb').read()
    png16(os.path.join(d, 'rtl.png'), rtl, width)

    def diff(a, b_, tag):
        n = sum(1 for i in range(0, fbn, 2) if a[i:i + 2] != b_[i:i + 2])
        rows = sorted({(i // 2) // width for i in range(0, fbn, 2) if a[i:i + 2] != b_[i:i + 2]})
        print('  %-14s %6d pixels differ%s' % (tag, n, (', rows %d-%d' % (rows[0], rows[-1])) if rows else ''))
    diff(model, rtl, 'model vs RTL')
    diff(model, board, 'model vs board')
    diff(rtl, board, 'RTL vs board')
    print(d)


if __name__ == '__main__':
    cmd, name = sys.argv[1], sys.argv[2]
    {'grab': grab, 'prep': prep, 'check': check}[cmd](name)
