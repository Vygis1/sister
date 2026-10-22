"""rdpmodes.py - the RDP's texture and pixel modes, one case a square, model against RTL.

rdpmatrix.py covers the texture formats and loads; this covers the modes krom's tests leave
out or touch once: YUV textures (point, quad, bilinear, mid-texel; converted or not), the
texture convert stage on any format (BILERP off: SET_CONVERT's K0-K3), convert_one (two-cycle
G_TC_FILTCONV, with and without BILERP1), the one-cycle pipelined TEXEL1 (texture rectangles,
left- and right-major triangles, perspective, a span's end pixel taking the next scanline's
start), noise (the combiner's NOISE, the noise dithers, alpha compare against noise), an
interlaced scissor's dither, and the colour image formats (16-bit, 32-bit, 8-bit, 4-bit).

Each case is drawn in its own 34 x 34 square of one 320 x 240 picture; tools/n64/n64rdp.py draws
the list, sim/tb_n64_rdp.v replays it into the RTL, and the squares that differ name the mode.

    python tools/n64/rdpmodes.py [--fb 16|32|8|4] [--seed N] [CASE ...]   -> sim/n64d/
    ./tools/sim.sh tb_n64_rdp
    python tools/n64/rdpmodes.py --check [--fb ...]
"""
import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import n64rdp      # noqa: E402
import n64rdpsim   # noqa: E402

OUT = os.path.join(HERE, '..', '..', 'sim', 'n64d')
RAM = 8 << 20
FB, FBW, FBH = 0x100000, 320, 240
ZB = 0x180000
TEX = 0x200000
CMDS = 0x300000
CELL = 38

arg = lambda k, d: sys.argv[sys.argv.index(k) + 1] if k in sys.argv else d
FBBITS = int(arg('--fb', '16'))
SEED = int(arg('--seed', '7'))
ONLY = [a for i, a in enumerate(sys.argv[1:]) if not a.startswith('--') and sys.argv[i] not in ('--fb', '--seed')]
FB_SIZE = {4: 0, 8: 1, 16: 2, 32: 3}[FBBITS]
FB_BPP = 8 if FBBITS == 4 else FBBITS          # (the model keeps a 4-bit image a byte a pixel)


class Bus:
    def __init__(self):
        self.rdram = bytearray(RAM)
        self.dmem = bytearray(4096)
        self.mi_intr = 0


def cmd(lst, w0, w1):
    lst.append(((w0 & 0xFFFFFFFF) << 32) | (w1 & 0xFFFFFFFF))


# --- the combiner ------------------------------------------------------------------------------
T0, T1, PRIM, SHADE, ENV, ONE, NOISE, ZERO = 1, 2, 3, 4, 5, 6, 7, 8
COMB = 0


def combine(c0, c1):
    """c = (rgb A, B, C, D, alpha A, B, C, D) per cycle -> SET_COMBINE's words"""
    w0 = ((0x3C << 24) | (c0[0] << 20) | (c0[2] << 15) | (c0[4] << 12) | (c0[6] << 9) | (c1[0] << 5) | c1[2])
    w1 = ((c0[1] << 28) | (c1[1] << 24) | (c1[4] << 21) | (c1[6] << 18) | (c0[3] << 15) | (c0[5] << 12)
          | (c0[7] << 9) | (c1[3] << 6) | (c1[5] << 3) | c1[7])
    return w0, w1


def thru(src):
    """the cycle's output is src (1 TEXEL0, 2 TEXEL1, 0 COMBINED, 4 SHADE)"""
    return (15, 15, 31, src, 7, 7, 7, src)


# (TEXEL1 - TEXEL0) * PRIM_LOD_FRAC + TEXEL0, as krom's RDPTex0And1
LERP01 = (T1, T0, 14, T0, T1, T0, 6, T0)
NOISE_ADD = (NOISE, 15, 4, T0, 7, 7, 7, T0)         # (NOISE - 0) * SHADE + TEXEL0


# --- other modes ---------------------------------------------------------------------------------
def other_modes(cyc=0, persp=0, tlut=0, tlut_type=0, sq=0, mid=0, bl0=1, bl1=1, conv1=0, rgb_d=3, a_d=3,
                force_blend=0, alpha_test=0, alpha_dith=0, aa=0, blend=0, cvg_dest=0, image_read=0,
                zcmp=0, zupd=0, cvg_ta=0, acs=0, lod=0, sharpen=0, detail=0):
    w0 = ((0x2F << 24) | (cyc << 20) | (persp << 19) | (detail << 18) | (sharpen << 17) | (lod << 16)
          | (tlut << 15) | (tlut_type << 14) | (sq << 13) | (mid << 12) | (bl0 << 11) | (bl1 << 10)
          | (conv1 << 9) | (rgb_d << 6) | (a_d << 4))
    w1 = ((blend << 16) | (force_blend << 14) | (acs << 13) | (cvg_ta << 12) | (cvg_dest << 8)
          | (image_read << 6) | (zupd << 5) | (zcmp << 4) | (aa << 3) | (alpha_dith << 1) | alpha_test)
    return w0, w1


# --- primitives ------------------------------------------------------------------------------------
def s1616(v):
    return int(round(v * 65536)) & 0xFFFFFFFF


def quad_words(vals):
    """four s15.16 values -> the four words n64rdp._quad reads (int halves i, i+1; fractions j, j+1)"""
    v = [x & 0xFFFFFFFF for x in vals]
    wi0 = (v[0] & 0xFFFF0000) | (v[1] >> 16)
    wi1 = (v[2] & 0xFFFF0000) | (v[3] >> 16)
    wj0 = ((v[0] & 0xFFFF) << 16) | (v[1] & 0xFFFF)
    wj1 = ((v[2] & 0xFFFF) << 16) | (v[3] & 0xFFFF)
    return wi0, wi1, wj0, wj1


def attr_block(base, ddx, dde, ddy):
    """16 words: values (0, 1 int; 4, 5 frac), dx (2, 3; 6, 7), de (8, 9; 12, 13), dy (10, 11; 14, 15)"""
    a = quad_words(base)
    b = quad_words(ddx)
    c = quad_words(dde)
    d = quad_words(ddy)
    w = [0] * 16
    w[0], w[1], w[4], w[5] = a
    w[2], w[3], w[6], w[7] = b
    w[8], w[9], w[12], w[13] = c
    w[10], w[11], w[14], w[15] = d
    return w


def triangle(cl, verts, tile=0, shade=True, tex=True, z=False):
    """a triangle from three vertices {x, y, (r, g, b, a), (s, t, w), z}: edges as libdragon's
    rdpq_triangle sets them up, the attributes from the plane through the three"""
    v = sorted(verts, key=lambda p: p['y'])
    (x1, y1), (x2, y2), (x3, y3) = [(p['x'], p['y']) for p in v]
    y1f, y2f, y3f = int(y1 * 4) & 0x3FFF, int(y2 * 4) & 0x3FFF, int(y3 * 4) & 0x3FFF
    hx, hy, mx, my, lx, ly = x3 - x1, y3 - y1, x2 - x1, y2 - y1, x3 - x2, y3 - y2
    nz = hx * my - hy * mx
    lft = 1 if nz < 0 else 0
    ish = hx / hy if abs(hy) > 1e-9 else 0
    ism = mx / my if abs(my) > 1e-9 else 0
    isl = lx / ly if abs(ly) > 1e-9 else 0
    fy = (int(y1 * 4) / 4.0) - y1
    cy = (int(y2 * 4) / 4.0) - y2
    xh = x1 + fy * ish
    xm = x1 + fy * ism
    xl = x2 + cy * isl
    op = 0x08 | (4 if shade else 0) | (2 if tex else 0) | (1 if z else 0)
    w = [(op << 24) | (lft << 23) | (tile << 16) | y3f, (y2f << 16) | y1f,
         s1616(xl), s1616(isl), s1616(xh), s1616(ish), s1616(xm), s1616(ism)]

    def plane(get):
        a1, a2, a3 = get(v[0]), get(v[1]), get(v[2])
        det = (x2 - x1) * (y3 - y1) - (x3 - x1) * (y2 - y1)
        if abs(det) < 1e-9:
            return a1, 0.0, 0.0, 0.0
        dx = ((a2 - a1) * (y3 - y1) - (a3 - a1) * (y2 - y1)) / det
        dy = ((a3 - a1) * (x2 - x1) - (a2 - a1) * (x3 - x1)) / det
        return a1 + fy * (dy + dx * ish), dx, dy + dx * ish, dy

    if shade:
        ps = [plane(lambda p, i=i: p['rgba'][i]) for i in range(4)]
        w += attr_block([s1616(p[0]) for p in ps], [s1616(p[1]) for p in ps], [s1616(p[2]) for p in ps],
                        [s1616(p[3]) for p in ps])
    if tex:
        ps = [plane(lambda p, i=i: p['stw'][i]) for i in range(3)] + [(0, 0, 0, 0)]
        w += attr_block([s1616(p[0]) for p in ps], [s1616(p[1]) for p in ps], [s1616(p[2]) for p in ps],
                        [s1616(p[3]) for p in ps])
    if z:
        p = plane(lambda p: p['z'])
        w += [s1616(p[0]), s1616(p[1]), s1616(p[2]), s1616(p[3])]
    for i in range(0, len(w), 2):
        cmd(cl, w[i], w[i + 1])


def texrect(cl, x0, y0, x1, y1, tile, s, t, dsdx, dtdy, flip=False):
    """(x0, y0)-(x1, y1) in pixels (10.2 as given, *4); s, t s10.5; dsdx, dtdy s5.10"""
    cmd(cl, ((0x25 if flip else 0x24) << 24) | ((x1 & 0xFFF) << 12) | (y1 & 0xFFF),
        (tile << 24) | ((x0 & 0xFFF) << 12) | (y0 & 0xFFF))
    cmd(cl, ((s & 0xFFFF) << 16) | (t & 0xFFFF), ((dsdx & 0xFFFF) << 16) | (dtdy & 0xFFFF))


# --- textures ------------------------------------------------------------------------------------
FMT = {'RGBA': 0, 'YUV': 1, 'CI': 2, 'IA': 3, 'I': 4}
SIZ = {4: 0, 8: 1, 16: 2, 32: 3}


class Tex:
    def __init__(self, fmt, bits, w, h, addr, tmem, tile, mask=0, mirror=0, clamp=0, shift=0):
        self.fmt, self.bits, self.w, self.h = fmt, bits, w, h
        self.addr, self.tmem, self.tile = addr, tmem, tile
        self.mask, self.mirror, self.clamp, self.shift = mask, mirror, clamp, shift
        line = (w * bits // 8 + 7) // 8
        self.line = line // 2 if (bits == 32 or fmt == 'YUV') else line


def load_tex(cl, bus, rnd, tx):
    tbytes = tx.w * tx.h * tx.bits // 8
    bus.rdram[tx.addr:tx.addr + tbytes] = bytes(rnd.getrandbits(8) for _ in range(tbytes))
    isz = SIZ[tx.bits]
    ifmt = 0 if tx.fmt == 'YUV' else FMT[tx.fmt]
    cmd(cl, 0x27 << 24, 0)
    cmd(cl, (0x3D << 24) | (ifmt << 21) | (isz << 19) | (tx.w - 1), tx.addr)
    cmd(cl, 0x28 << 24, 0)
    cmd(cl, (0x35 << 24) | (FMT[tx.fmt] << 21) | (isz << 19) | (tx.line << 9) | (tx.tmem >> 3), (7 << 24))
    cmd(cl, 0x26 << 24, 0)
    cmd(cl, (0x34 << 24) | 0, (7 << 24) | (((tx.w - 1) << 2) << 12) | ((tx.h - 1) << 2))
    set_tile(cl, tx)


def set_tile(cl, tx):
    ms, mt = tx.mask, tx.mask
    cmd(cl, 0x28 << 24, 0)
    cmd(cl, (0x35 << 24) | (FMT[tx.fmt] << 21) | (SIZ[tx.bits] << 19) | (tx.line << 9) | (tx.tmem >> 3),
        (tx.tile << 24) | (tx.clamp << 19) | (tx.mirror << 18) | (mt << 14) | (tx.shift << 10)
        | (tx.clamp << 9) | (tx.mirror << 8) | (ms << 4) | tx.shift)
    cmd(cl, (0x32 << 24) | 0, (tx.tile << 24) | (((tx.w - 1) << 2) << 12) | ((tx.h - 1) << 2))


# --- the cases -----------------------------------------------------------------------------------
# each: (name, modes(dict), combine (c0, c1), texture (fmt, bits), prim kind, extra)
def case_list():
    L = []
    k = {}

    def add(name, prim='rect', fmt=('RGBA', 16), comb=(thru(T0), thru(T0)), **m):
        L.append((name, m, comb, fmt, prim))
    # YUV
    add('yuv_point_conv', fmt=('YUV', 16), bl0=0, bl1=0)
    add('yuv_quad_conv', fmt=('YUV', 16), sq=1, bl0=0, bl1=0)
    add('yuv_quad_bilerp', fmt=('YUV', 16), sq=1)
    add('yuv_mid', fmt=('YUV', 16), sq=1, mid=1)
    add('yuv_mid_conv', fmt=('YUV', 16), sq=1, mid=1, bl0=0, bl1=0)
    add('yuv_tri_bilerp', prim='tri_l', fmt=('YUV', 16), sq=1)
    add('yuv_tri_persp', prim='tri_p', fmt=('YUV', 16), sq=1, persp=1, bl0=0, bl1=0)
    # the convert stage on other formats
    add('rgba16_conv', bl0=0, bl1=0)
    add('rgba32_conv', fmt=('RGBA', 32), bl0=0, bl1=0, sq=1)
    add('ia8_conv', fmt=('IA', 8), bl0=0, bl1=0, sq=1)
    # two-cycle G_TC_FILTCONV: cycle 0 TEXEL0 filtered, cycle 1 TEXEL1 = convert(TEXEL0)
    add('filtconv_yuv', fmt=('YUV', 16), cyc=1, sq=1, bl0=1, bl1=0, conv1=1, comb=(thru(T1), thru(T0)))
    add('filtconv_rgba', cyc=1, sq=1, bl0=1, bl1=0, conv1=1, comb=(thru(T1), thru(T0)))
    # convert_one with BILERP1: TEXEL1 filtered with TEXEL0 as factors
    add('conv1_bl_yuv', fmt=('YUV', 16), cyc=1, sq=1, bl0=1, bl1=1, conv1=1, comb=(thru(T1), thru(T0)))
    add('conv1_bl_yuv_mid', fmt=('YUV', 16), cyc=1, sq=1, mid=1, bl0=1, bl1=1, conv1=1, comb=(thru(T1), thru(T0)))
    add('conv1_bl_rgba', cyc=1, sq=1, bl0=1, bl1=1, conv1=1, comb=(thru(T1), thru(T0)))
    add('conv1_bl_rgba_mid', cyc=1, sq=1, mid=1, bl0=1, bl1=1, conv1=1, comb=(thru(T1), thru(T0)))
    add('conv1_nosq', cyc=1, sq=0, bl0=1, bl1=1, conv1=1, comb=(thru(T1), thru(T0)))
    add('conv1_tri', prim='tri_r', cyc=1, sq=1, bl0=1, bl1=1, conv1=1, comb=(thru(T1), thru(T0)))
    add('cyc2_conv0', cyc=1, sq=1, bl0=0, bl1=1, comb=(thru(T0), LERP01))
    # one-cycle pipelined TEXEL1
    add('pt1_rect', sq=1, comb=(LERP01, LERP01))
    add('pt1_rect_point', comb=(LERP01, LERP01))
    add('pt1_rect_narrow', prim='rect6', sq=1, comb=(LERP01, LERP01))
    add('pt1_rect_conv1', fmt=('YUV', 16), sq=1, bl0=1, bl1=1, conv1=1, comb=(thru(T1), thru(T1)))
    add('pt1_tri_l', prim='tri_l', sq=1, comb=(LERP01, LERP01))
    add('pt1_tri_r', prim='tri_r', sq=1, comb=(LERP01, LERP01))
    add('pt1_tri_persp', prim='tri_p', sq=1, persp=1, comb=(LERP01, LERP01))
    add('pt1_tri_persp_r', prim='tri_pr', sq=1, persp=1, comb=(LERP01, LERP01))
    add('pt1_interlace', prim='rect_il', sq=1, comb=(LERP01, LERP01))
    # noise
    add('noise_comb', comb=(NOISE_ADD, NOISE_ADD), prim='tri_l')
    add('noise_dither_rgb', rgb_d=2, a_d=3, comb=(thru(T0), thru(T0)))
    add('noise_dither_alpha', rgb_d=0, a_d=2, cyc=0, comb=(thru(T0), thru(T0)))
    add('noise_alpha_test', alpha_test=1, alpha_dith=1, comb=(thru(T0), thru(T0)))
    add('noise_cyc2', cyc=1, comb=(NOISE_ADD, NOISE_ADD), prim='tri_r')
    # dither (the magic square / Bayer) with an interlaced scissor
    add('dither_interlace', prim='rect_il', rgb_d=0, a_d=0)
    add('dither_bayer', rgb_d=1, a_d=1)
    if ONLY:
        L = [c for c in L if any(c[0].startswith(o) for o in ONLY)]
    return L


def build():
    rnd = random.Random(SEED)
    bus = Bus()
    r = n64rdp.RDP(bus)
    r.hidden = n64rdpsim.ConstHidden(len(bus.rdram) >> 1)
    cl = []
    cmd(cl, (0x3F << 24) | (0 << 21) | (FB_SIZE << 19) | (FBW - 1), FB)
    cmd(cl, (0x3E << 24), ZB)
    cmd(cl, (0x2D << 24), ((FBW << 2) << 12) | (FBH << 2))
    # SET_CONVERT: libultra's YUV-to-RGB (G_CV_K0..K5)
    k = [175, -43, -89, 222, 114, 42]
    m = 0
    for v in k:
        m = (m << 9) | (v & 0x1FF)
    cmd(cl, (0x2C << 24) | (m >> 32), m & 0xFFFFFFFF)
    cmd(cl, 0x3A << 24 | 0x60, 0x80C040FF)               # prim colour, prim LOD frac 0x60
    cmd(cl, 0x3B << 24, 0x30A0E0C0)                      # env
    cmd(cl, 0x39 << 24, 0x00000080)                      # blend colour (alpha compare's threshold 0x80)
    # fill the framebuffer with a pattern first (so a pixel not written shows)
    taddr = TEX
    placed = []
    for n, (name, m, comb, fmt, prim) in enumerate(case_list()):
        per_row = FBW // CELL
        x0, y0 = 2 + (n % per_row) * CELL, 2 + (n // per_row) * CELL
        il = prim == 'rect_il'
        # the scissor: the whole picture, or (interlaced) every other line of it
        cmd(cl, 0x27 << 24, 0)
        cmd(cl, (0x2D << 24), ((3 if il else 0) << 24) | ((FBW << 2) << 12) | (FBH << 2))
        tx = Tex(fmt[0], fmt[1], 16, 16, taddr, 0, 0, mask=4, mirror=n & 1)
        load_tex(cl, bus, rnd, tx)
        # a second tile (TEXEL1 in two-cycle mode, and tile + 1): the same texels, another wrap
        tx1 = Tex(fmt[0], fmt[1], 16, 16, taddr, 0, 1, mask=3, mirror=(n >> 1) & 1, shift=1)
        set_tile(cl, tx1)
        cmd(cl, 0x27 << 24, 0)
        w0, w1 = other_modes(**m)
        cmd(cl, w0, w1)
        cmd(cl, *combine(*comb))
        if prim in ('rect', 'rect_il', 'rect6'):
            wd = 6 if prim == 'rect6' else 32
            # s, t from a fraction, dsdx 0.75 texels a pixel, dtdy 0.625: fractions everywhere
            texrect(cl, x0 << 2, y0 << 2, (x0 + wd) << 2, (y0 + 32) << 2, 0, (3 << 5) | 7, (1 << 5) | 21,
                    (3 << 10) // 4, (5 << 10) // 8)
        else:
            def vert(x, y, s, t, w=1.0):
                ww = w * 0x7FFF if m.get('persp') else 0
                sc = (ww / 0x8000) if m.get('persp') else 1.0
                return {'x': x, 'y': y, 'rgba': [rnd.uniform(16, 240) for _ in range(4)],
                        'stw': [s * 32 * sc, t * 32 * sc, ww], 'z': rnd.uniform(0, 0x3FFF)}
            if prim in ('tri_l', 'tri_p'):
                vs = [vert(x0 + 2.3, y0 + 1.6, 0.4, 0.7, 1.0), vert(x0 + 31.1, y0 + 9.4, 21.5, 3.2, 0.6),
                      vert(x0 + 6.7, y0 + 31.2, 4.1, 25.9, 0.35)]
            else:
                vs = [vert(x0 + 29.6, y0 + 1.3, 0.2, 0.3, 0.9), vert(x0 + 1.2, y0 + 14.8, 18.7, 6.1, 0.45),
                      vert(x0 + 24.9, y0 + 31.4, 9.3, 27.6, 1.0)]
            triangle(cl, vs, tile=0, shade=True, tex=True)
        placed.append((n, name, x0, y0))
        taddr += 0x1000
    cmd(cl, 0x29 << 24, 0)
    for i, c in enumerate(cl):
        struct.pack_into('>Q', bus.rdram, CMDS + 8 * i, c)
    # the framebuffer's starting pattern
    fbbytes = FBW * FBH * FB_BPP // 8
    bus.rdram[FB:FB + fbbytes] = bytes((i * 37 + 11) & 0xFF for i in range(fbbytes))
    rd0 = bytearray(bus.rdram)
    end = CMDS + 8 * len(cl)
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
    open(os.path.join(OUT, 'rdp_lines.txt'), 'w').write(' '.join('%x' % l for l in range(FB >> 4, (FB + fbbytes) >> 4)))
    open(os.path.join(OUT, 'after.bin'), 'wb').write(bytes(bus.rdram))
    open(os.path.join(OUT, 'vi.txt'), 'w').write('%x %x %x\n' % (0x3 if FBBITS == 32 else 0x2, FB, FBW))
    open(os.path.join(OUT, 'modes.txt'), 'w').write('\n'.join('%d %s %d %d' % p for p in placed))
    changed = sum(1 for a in range(FB, FB + fbbytes, 16) if rd0[a:a + 16] != bus.rdram[a:a + 16])
    print('%d cases, %d commands, %d pixels drawn by the model, %d framebuffer lines changed'
          % (len(placed), r.commands, r.pixels, changed))


def check():
    want = open(os.path.join(OUT, 'after.bin'), 'rb').read()
    start = bytearray()
    for l in open(os.path.join(OUT, 'rdram.hex')):
        start += bytes.fromhex(l.strip())[::-1]
    got = bytearray(start)
    for l in open(os.path.join(OUT, 'rtl_lines.hex')):
        a, d = l.split()
        a = int(a, 16) * 16
        got[a:a + 16] = bytes.fromhex(d)[::-1]
    bad = 0
    placed = [l.split() for l in open(os.path.join(OUT, 'modes.txt'))]
    for p in placed:
        n, name, x0, y0 = int(p[0]), p[1], int(p[2]), int(p[3])
        diff = drawn = 0
        for y in range(y0, y0 + 34):
            for x in range(x0, x0 + 34):
                bit = (y * FBW + x) * FB_BPP
                a, nb = FB + bit // 8, max(1, FB_BPP // 8)
                if want[a:a + nb] != got[a:a + nb]:
                    diff += 1
                if want[a:a + nb] != start[a:a + nb]:
                    drawn += 1
        bad += diff != 0
        print('  %s %-20s %4d pixels differ (the model drew %d)' % ('ok  ' if diff == 0 else 'FAIL', name, diff, drawn))
    # anything outside the squares
    other = sum(1 for a in range(0, RAM, 16) if want[a:a + 16] != got[a:a + 16]
                and not (FB <= a < FB + FBW * FBH * FB_BPP // 8))
    if other:
        print('  FAIL %d lines differ outside the framebuffer' % other)
        bad += 1
    print('%d of %d cases differ' % (bad, len(placed)))
    return bad == 0


if __name__ == '__main__':
    if '--check' in sys.argv:
        sys.exit(0 if check() else 1)
    build()
