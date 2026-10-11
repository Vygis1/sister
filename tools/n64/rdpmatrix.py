"""rdpmatrix.py - the RDP's texture paths, one case each, model against RTL.

Every texture format and size (RGBA16/32, CI4/CI8 through a TLUT, IA4/8/16, I4/8), loaded by
LOAD_BLOCK and by LOAD_TILE, drawn as a 32x32 TEXTURE_RECTANGLE in 1-cycle and in copy mode,
each case in its own square of one 320x240 RGBA16 picture. tools/n64/n64rdp.py (from
parallel-RDP) draws it; sim/tb_n64_rdp.v replays the same commands into the RTL; the squares
that differ name the broken path.

    python tools/n64/rdpmatrix.py            -> sim/n64d/ (as tools/n64/n64rdpsim.py captures)
    ./tools/sim.sh tb_n64_rdp
    python tools/n64/rdpmatrix.py --check     which cases differ (and build/rdpmatrix_*.png)
    --w N  textures N texels wide (default 32): rows that are not a power of two of TMEM words
           make LOAD_BLOCK's dxt uneven (its odd-row swaps drift). For LOAD_BLOCK a row must be a
           whole number of 64-bit words, as libultra requires (I4: N a multiple of 16, 8-bit: 8,
           16-bit: 4, 32-bit: 2)
"""
import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import n64rdp      # noqa: E402
import n64rdpsim   # noqa: E402
import n64model    # noqa: E402

OUT = os.path.join(HERE, '..', '..', 'sim', 'n64d')
RAM = 8 << 20
FB, FBW, FBH = 0x100000, 320, 240
TEX = 0x200000
CMDS = 0x300000

FMT = {'RGBA': 0, 'YUV': 1, 'CI': 2, 'IA': 3, 'I': 4}
SIZ = {4: 0, 8: 1, 16: 2, 32: 3}
FORMATS = [('RGBA', 16), ('RGBA', 32), ('CI', 4), ('CI', 8), ('IA', 4), ('IA', 8), ('IA', 16), ('I', 4), ('I', 8)]


class Bus:
    def __init__(self):
        self.rdram = bytearray(RAM)
        self.dmem = bytearray(4096)
        self.mi_intr = 0


def cmd(lst, w0, w1):
    lst.append(((w0 & 0xFFFFFFFF) << 32) | (w1 & 0xFFFFFFFF))


def other_modes(cycle, tlut):
    # cycle 0 = 1-cycle, 2 = copy; dithers off (3, 3); bi_lerp0; TLUT on with RGBA16 entries
    w0 = (0x2F << 24) | (cycle << 20) | (tlut << 15) | (1 << 11) | (3 << 6) | (3 << 4)
    w1 = 0
    if cycle == 2:
        w1 |= 1                                   # alpha compare: a zero alpha texel is not written
    return w0, w1


WIDTH = int(sys.argv[sys.argv.index('--w') + 1]) if '--w' in sys.argv else 32
ONLY = [a for a in sys.argv[1:] if not a.startswith('--') and a != str(WIDTH)]   # e.g. CI:4:block:0


def cases():
    out = []
    for fi, (fmt, bits) in enumerate(FORMATS):
        for load in ('block', 'tile'):
            for cyc in (0, 2):
                if cyc == 2 and bits == 32:
                    continue                      # copy mode has no 32-bit texels
                tag = '%s:%d:%s:%d' % (fmt, bits, load, cyc)
                if ONLY and not any(tag.startswith(o) for o in ONLY):
                    continue
                out.append((fmt, bits, load, cyc))
    return out


def build():
    rnd = random.Random(64)
    bus = Bus()
    r = n64rdp.RDP(bus)
    r.hidden = n64rdpsim.ConstHidden(len(bus.rdram) >> 1)
    cl = []
    cmd(cl, (0x3F << 24) | (0 << 21) | (2 << 19) | (FBW - 1), FB)              # colour image RGBA16
    cmd(cl, (0x2D << 24), ((FBW << 2) << 12) | (FBH << 2))                     # scissor
    # combiner: TEXEL0 straight through, colour and alpha, both cycles
    cmd(cl, (0x3C << 24) | (15 << 20) | (31 << 15) | (7 << 12) | (7 << 9) | (15 << 5) | 31,
        (15 << 28) | (15 << 24) | (7 << 21) | (7 << 18) | (1 << 15) | (7 << 12) | (1 << 9) | (1 << 6) | (7 << 3) | 1)
    # a TLUT for the CI cases: 256 RGBA16 entries, non-zero alpha bit set, at TEX + 0xF0000
    tlut_addr = TEX + 0xF0000
    for i in range(256):
        struct.pack_into('>H', bus.rdram, tlut_addr + 2 * i, (rnd.getrandbits(15) << 1) | 1)
    taddr = TEX
    placed = []
    for n, (fmt, bits, load, cyc) in enumerate(cases()):
        W, H = WIDTH, 32
        per_row = (FBW - 4) // (W + 7)
        x0, y0 = 4 + (n % per_row) * (W + 7), 4 + (n // per_row) * 39
        tbytes = W * H * bits // 8
        data = bytes(rnd.getrandbits(8) for _ in range(tbytes))
        bus.rdram[taddr:taddr + tbytes] = data
        line = (W * bits // 8 + 7) // 8                                     # TMEM words a row
        # (a 32-bit tile's line counts each 2 kB half's doublewords: half the bytes, as
        # libultra's G_IM_SIZ_32b_LINE_BYTES; LOAD_BLOCK's dxt still counts all of them)
        tline = line // 2 if bits == 32 else line
        cmd(cl, 0x27 << 24, 0)                                              # SYNC_PIPE
        mw0, mw1 = other_modes(cyc, 1 if fmt == 'CI' else 0)
        cmd(cl, mw0, mw1)
        if fmt == 'CI':
            # LOAD_TLUT: the palette into the high half of TMEM (address 256 words)
            cmd(cl, (0x3D << 24) | (0 << 21) | (2 << 19) | 0, tlut_addr)
            cmd(cl, 0x28 << 24, 0)                                          # SYNC_TILE
            # (the load tile 4-bit, as libultra's gDPLoadTLUT sets it: an entry every 4 words)
            cmd(cl, (0x35 << 24) | (0 << 21) | (0 << 19) | 256, (6 << 24))
            cmd(cl, 0x26 << 24, 0)                                          # SYNC_LOAD
            cmd(cl, (0x30 << 24) | 0, (6 << 24) | ((255 << 2) << 12) | 0)
        # the texture image, and the load
        if load == 'block':
            # LOAD_BLOCK wants the image as 16-bit (4/8-bit textures are loaded as 16-bit words)
            lsize = 2 if bits <= 16 else 3
            texels = tbytes // (2 if lsize == 2 else 4)
            dxt = (2048 + line - 1) // line if lsize == 2 else (2048 + line - 1) // line
            cmd(cl, (0x3D << 24) | (FMT[fmt] << 21) | (lsize << 19) | 0, taddr)
            cmd(cl, 0x28 << 24, 0)
            cmd(cl, (0x35 << 24) | (FMT[fmt] << 21) | (lsize << 19) | (0 << 9) | 0, (7 << 24))
            cmd(cl, 0x26 << 24, 0)
            cmd(cl, (0x33 << 24) | 0, (7 << 24) | ((texels - 1) << 12) | dxt)
        else:
            cmd(cl, (0x3D << 24) | (FMT[fmt] << 21) | (SIZ[bits] << 19) | (W - 1), taddr)
            cmd(cl, 0x28 << 24, 0)
            cmd(cl, (0x35 << 24) | (FMT[fmt] << 21) | (SIZ[bits] << 19) | (tline << 9) | 0, (7 << 24))
            cmd(cl, 0x26 << 24, 0)
            cmd(cl, (0x34 << 24) | 0, (7 << 24) | (((W - 1) << 2) << 12) | ((H - 1) << 2))
        # the render tile: the format itself, a row of `line` words, palette 0
        cmd(cl, 0x28 << 24, 0)
        cmd(cl, (0x35 << 24) | (FMT[fmt] << 21) | (SIZ[bits] << 19) | (tline << 9) | 0, (0 << 24))
        cmd(cl, (0x32 << 24) | 0, (0 << 24) | (((W - 1) << 2) << 12) | ((H - 1) << 2))
        cmd(cl, 0x27 << 24, 0)
        # TEXTURE_RECTANGLE: (x0, y0) to (x0 + W, y0 + H), s/t from 0, a texel a pixel (4 in copy)
        xh, yh = x0 << 2, y0 << 2
        xl, yl = (x0 + W - (1 if cyc == 2 else 0)) << 2, (y0 + H - (1 if cyc == 2 else 0)) << 2
        dsdx = (4 << 10) if cyc == 2 else (1 << 10)
        cmd(cl, (0x24 << 24) | (xl << 12) | yl, (0 << 24) | (xh << 12) | yh)
        cmd(cl, (0 << 16) | 0, (dsdx << 16) | (1 << 10))
        placed.append((n, fmt, bits, load, cyc, x0, y0))
        taddr += (tbytes + 0xFFF) & ~0xFFF
    cmd(cl, 0x29 << 24, 0)                                                   # SYNC_FULL
    for i, c in enumerate(cl):
        struct.pack_into('>Q', bus.rdram, CMDS + 8 * i, c)
    rd0 = bytearray(bus.rdram)
    end = CMDS + 8 * len(cl)
    # the model draws it
    writes = [(3, 1 | 4 | 16), (0, CMDS), (1, end)]
    for i, v in writes:
        r.reg_write(i, v)
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, 'rdram.hex'), 'w') as f:
        for a in range(0, RAM, 16):
            f.write(rd0[a:a + 16][::-1].hex() + '\n')
    with open(os.path.join(OUT, 'tmem.hex'), 'w') as f:
        f.write('0000\n' * 2048)
    with open(os.path.join(OUT, 'writes.hex'), 'w') as f:
        f.write('%x\n' % len(writes))
        for i, v in writes:
            f.write('0 %x %08x\n' % (i, v))
    changed = [a >> 4 for a in range(FB, FB + FBW * FBH * 2, 16) if rd0[a:a + 16] != bus.rdram[a:a + 16]]
    open(os.path.join(OUT, 'rdp_lines.txt'), 'w').write(' '.join('%x' % l for l in range(FB >> 4, (FB + FBW * FBH * 2) >> 4)))
    open(os.path.join(OUT, 'after.bin'), 'wb').write(bytes(bus.rdram))
    open(os.path.join(OUT, 'vi.txt'), 'w').write('%x %x %x\n' % (0x3, FB, FBW))
    open(os.path.join(OUT, 'matrix.txt'), 'w').write('\n'.join(' '.join(str(v) for v in p) for p in placed))
    print('%d cases, %d commands, %d pixels drawn by the model, %d framebuffer lines changed'
          % (len(placed), r.commands, r.pixels, len(changed)))


def check():
    rd0 = open(os.path.join(OUT, 'after.bin'), 'rb').read()
    got = bytearray(RAM)
    for l in open(os.path.join(OUT, 'rdram.hex')):
        pass
    # RTL: the lines it wrote, over the starting RDRAM
    start = bytearray()
    for l in open(os.path.join(OUT, 'rdram.hex')):
        start += bytes.fromhex(l.strip())[::-1]
    got = bytearray(start)
    for l in open(os.path.join(OUT, 'rtl_lines.hex')):
        a, d = l.split()
        a = int(a, 16) * 16
        got[a:a + 16] = bytes.fromhex(d)[::-1]
    placed = [l.split() for l in open(os.path.join(OUT, 'matrix.txt'))]
    bad = 0
    for p in placed:
        n, fmt, bits, load, cyc, x0, y0 = int(p[0]), p[1], int(p[2]), p[3], int(p[4]), int(p[5]), int(p[6])
        diff = 0
        for y in range(y0, y0 + 32):
            for x in range(x0, x0 + WIDTH):
                a = FB + 2 * (y * FBW + x)
                if rd0[a:a + 2] != got[a:a + 2]:
                    diff += 1
        drawn = sum(1 for y in range(y0, y0 + 32) for x in range(x0, x0 + WIDTH)
                    if rd0[FB + 2 * (y * FBW + x):FB + 2 * (y * FBW + x) + 2] != start[FB + 2 * (y * FBW + x):FB + 2 * (y * FBW + x) + 2])
        tag = 'ok  ' if diff == 0 else 'FAIL'
        if diff:
            bad += 1
        print('  %s %-4s %2d-bit  %-5s %-6s  %4d of %d pixels differ (model drew %d)'
              % (tag, fmt, bits, load, '1cycle' if cyc == 0 else 'copy', diff, 32 * WIDTH, drawn))
    for name, mem in (('model', rd0), ('rtl', got)):
        m = n64model.N64(b'\0' * 0x1000)
        m.rdram[:] = mem[:len(m.rdram)]
        m.vi[0], m.vi[1], m.vi[2] = 0x3, FB, FBW
        w, h, rgb = m.framebuffer()
        n64model.write_png(os.path.join(HERE, '..', '..', 'build', 'rdpmatrix_%s.png' % name), w, h, rgb)
    print('%d of %d cases differ (pictures: build/rdpmatrix_model.png, build/rdpmatrix_rtl.png)' % (bad, len(placed)))
    return bad == 0


if __name__ == '__main__':
    if '--check' in sys.argv:
        sys.exit(0 if check() else 1)
    build()
