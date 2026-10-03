"""The N64's RDP for tools/n64model.py: its registers (DPC), its command walk,
and the whole pixel pipeline, integer for integer.

This model is derived from parallel-RDP by Hans-Kristian Arntzen
(https://github.com/Themaister/parallel-rdp), which is MIT licensed:

    Copyright (c) 2020 Themaister

    Permission is hereby granted, free of charge, to any person obtaining
    a copy of this software and associated documentation files (the
    "Software"), to deal in the Software without restriction, including
    without limitation the rights to use, copy, modify, merge, publish,
    distribute, sublicense, and/or sell copies of the Software, and to
    permit persons to whom the Software is furnished to do so, subject to
    the following conditions:

    The above copyright notice and this permission notice shall be
    included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
    EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
    MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
    IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
    CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
    TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
    SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

What comes from where in parallel-RDP: the command decode and the
per-primitive setup (rdp_device.cpp, rdp_renderer.cpp); the scanline setup
(shaders/span_setup.comp); the pixel (shaders/shading.h, coverage.h,
interpolation.h, perspective.h, texture.h, combiner.h, dither.h, noise.h);
the memory side (memory_interfacing.h, depth_test.h, blender.h, z_encode.h,
the blender's divider table from luts.hpp); TMEM loads (tmem_update.comp).
GLSL's 32-bit wrap-around is kept where it can matter (s32()).

The register side follows ares (ares/n64/rdp/io.cpp, ISC), as rtl/n64_rdp.v
does: START is taken only while no start is pending; END sets the end and, if a
start is pending, moves CURRENT to it; STATUS's write bits clear and set the
source (XBUS), freeze, flush and the counters. SYNC_FULL raises the DP
interrupt (MI bit 5).

Structure, for the RTL that is to be checked against it: each stage is a
function of integers -- decode_edges / decode_shade / decode_texture /
decode_z (command words to setup), span_setup (one scanline: the four
sub-scanline x extents and the attributes at its start), compute_coverage,
interpolate_rgba, interpolate_stz, perspective_divide, compute_lod,
sample_texture (with its texel fetches from TMEM), combiner_cycle0/1,
dither_coefficients, depth_test, blender, rgb_dither, blend_coverage,
z_compress, and the framebuffer formats (load_color, store_color, ...).
RDP.trace, if set to a list, collects per-pixel stage values for vectors.

Timing is not modelled: a command list runs to its end the moment END is
written, and the registers never read busy.

Where this differs from parallel-RDP (each from a krom screenshot of hardware):
- cycle 1 mode computes LOD_FRAC when the combiner reads it (parallel-RDP
  leaves it undefined there; Cycle1TextureRectangle* need the 2-cycle value);
- COPY mode into an 8-bit framebuffer with TLUT writes the entry's high byte to
  every pixel (InternalPalette).
Not modelled (as in parallel-RDP): chroma key (SET_KEY_* feed only the
combiner's inputs), LOAD_TLUT into a 32-bit tile, the RDP's timing.
"""
import base64
import zlib

M32 = 0xFFFFFFFF


def s32(v):
    v &= M32
    return v - 0x100000000 if v & 0x80000000 else v


def sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def msb(v):
    """GLSL findMSB for v >= 0 (-1 for 0)"""
    return v.bit_length() - 1


def lsb(v):
    """GLSL findLSB for v > 0"""
    return (v & -v).bit_length() - 1


def popcount(v):
    return bin(v).count('1')


# --- command lengths --------------------------------------------------------------------
def cmd_len(op):
    """a command's length in 64-bit words"""
    if 0x08 <= op <= 0x0F:
        return 4 + (8 if op & 4 else 0) + (8 if op & 2 else 0) + (2 if op & 1 else 0)
    if op in (0x24, 0x25):
        return 2
    return 1


# --- flags, as parallel-RDP's (shaders/data_structures.h) ---------------------------------
TRI_FLIP = 1 << 0
TRI_DO_OFFSET = 1 << 1
TRI_SKIP_XFRAC = 1 << 2
TRI_INTERLACE_FIELD = 1 << 3
TRI_INTERLACE_KEEP_ODD = 1 << 4
TRI_FILL_COPY_RASTER = 1 << 7

R_INTERLACE_FIELD = 1 << 0
R_INTERLACE_KEEP_ODD = 1 << 1
R_AA = 1 << 2
R_PERSPECTIVE = 1 << 3
R_TLUT = 1 << 4
R_TLUT_TYPE = 1 << 5
R_CVG_TIMES_ALPHA = 1 << 6
R_ALPHA_CVG_SELECT = 1 << 7
R_MULTI_CYCLE = 1 << 8
R_TEX_LOD = 1 << 9
R_SHARPEN_LOD = 1 << 10
R_DETAIL_LOD = 1 << 11
R_FILL = 1 << 12
R_COPY = 1 << 13
R_SAMPLE_QUAD = 1 << 14
R_ALPHA_TEST = 1 << 15
R_ALPHA_TEST_DITHER = 1 << 16
R_MID_TEXEL = 1 << 17
R_USES_TEXEL0 = 1 << 18
R_USES_TEXEL1 = 1 << 19
R_USES_LOD = 1 << 20
R_USES_PIPELINED_TEXEL1 = 1 << 21
R_CONVERT_ONE = 1 << 22
R_BILERP0 = 1 << 23
R_BILERP1 = 1 << 24
R_NEED_NOISE_DUAL = 1 << 25
R_NEED_NOISE = 1 << 28

DB_DEPTH_TEST = 1 << 0
DB_DEPTH_UPDATE = 1 << 1
DB_FORCE_BLEND = 1 << 3
DB_IMAGE_READ = 1 << 4
DB_COLOR_ON_CVG = 1 << 5
DB_MULTI_CYCLE = 1 << 6
DB_AA = 1 << 7
DB_DITHER = 1 << 8

TILE_CLAMP_S = 1 << 0
TILE_MIRROR_S = 1 << 1
TILE_CLAMP_T = 1 << 2
TILE_MIRROR_T = 1 << 3

FMT_RGBA, FMT_YUV, FMT_CI, FMT_IA, FMT_I = 0, 1, 2, 3, 4
FB_I4, FB_I8, FB_RGBA5551, FB_IA88, FB_RGBA8888 = 0, 1, 2, 3, 4
UPLOAD_TILE, UPLOAD_TLUT, UPLOAD_BLOCK = 0, 1, 2


# --- setup records ------------------------------------------------------------------------
class Tri:
    """the edge setup of a primitive (parallel-RDP TriangleSetup): x in s.15
    (the command's s.16 with its lowest bit dropped), y in s.11.2"""
    __slots__ = ('xh', 'xm', 'xl', 'yh', 'ym', 'yl', 'dxhdy', 'dxmdy', 'dxldy', 'flags', 'tile')

    def __init__(self):
        self.xh = self.xm = self.xl = self.yh = self.ym = self.yl = 0
        self.dxhdy = self.dxmdy = self.dxldy = 0
        self.flags = 0
        self.tile = 0


class Attr:
    """the attribute setup (parallel-RDP AttributeSetup): RGBA and STZW, each a
    value and its x, e (major edge) and y derivatives, s15.16"""
    __slots__ = ('rgba', 'drgba_dx', 'drgba_de', 'drgba_dy', 'stzw', 'dstzw_dx', 'dstzw_de', 'dstzw_dy')

    def __init__(self):
        self.rgba = [0, 0, 0, 0]
        self.drgba_dx = [0, 0, 0, 0]
        self.drgba_de = [0, 0, 0, 0]
        self.drgba_dy = [0, 0, 0, 0]
        self.stzw = [0, 0, 0, 0]
        self.dstzw_dx = [0, 0, 0, 0]
        self.dstzw_de = [0, 0, 0, 0]
        self.dstzw_dy = [0, 0, 0, 0]

    def copy(self):
        a = Attr()
        for k in Attr.__slots__:
            setattr(a, k, list(getattr(self, k)))
        return a


class Tile:
    """a tile descriptor: SET_TILE's fields and SET_TILE_SIZE's (10.2) bounds"""
    __slots__ = ('fmt', 'size', 'stride', 'offset', 'palette', 'mask_s', 'shift_s', 'mask_t', 'shift_t',
                 'flags', 'slo', 'shi', 'tlo', 'thi')

    def __init__(self):
        self.fmt = self.size = self.stride = self.offset = self.palette = 0
        self.mask_s = self.shift_s = self.mask_t = self.shift_t = 0
        self.flags = 0
        self.slo = self.shi = self.tlo = self.thi = 0

    def copy(self):
        t = Tile()
        for k in Tile.__slots__:
            setattr(t, k, getattr(self, k))
        return t


class Span:
    """one scanline of a primitive (parallel-RDP SpanSetup)"""
    __slots__ = ('rgba', 'stzw', 'xleft', 'xright', 'base_x', 'start_x', 'end_x', 'lodlength', 'valid')


# --- stage: command decode (rdp_device.cpp) ------------------------------------------------
def decode_edges(w, copy_cycle):
    """a triangle's first 8 words -> Tri"""
    t = Tri()
    flip = (w[0] >> 23) & 1
    sign_dxhdy = (w[5] >> 31) & 1
    t.flags = ((TRI_FLIP if flip else 0) | (TRI_DO_OFFSET if flip == sign_dxhdy else 0)
               | (TRI_SKIP_XFRAC if copy_cycle else 0))
    t.tile = (w[0] >> 16) & 63              # tile in bits 0-2, max mip level in bits 3-5
    t.yl = sext(w[0], 14)
    t.ym = sext(w[1] >> 16, 14)
    t.yh = sext(w[1], 14)
    t.xl = sext(w[2], 28) >> 1
    t.xh = sext(w[4], 28) >> 1
    t.xm = sext(w[6], 28) >> 1
    t.dxldy = sext(w[3] >> 2, 28) >> 1
    t.dxhdy = sext(w[5] >> 2, 28) >> 1
    t.dxmdy = sext(w[7] >> 2, 28) >> 1
    return t


def _quad(w, i, j):
    """four s15.16 values whose integer halves are in words i, i+1 and fractions in j, j+1"""
    return [s32((w[i] & 0xFFFF0000) | (w[j] >> 16)), s32(((w[i] << 16) & M32) | (w[j] & 0xFFFF)),
            s32((w[i + 1] & 0xFFFF0000) | (w[j + 1] >> 16)), s32(((w[i + 1] << 16) & M32) | (w[j + 1] & 0xFFFF))]


def decode_shade(a, w):
    a.rgba = _quad(w, 0, 4)
    a.drgba_dx = _quad(w, 2, 6)
    a.drgba_de = _quad(w, 8, 12)
    a.drgba_dy = _quad(w, 10, 14)


def decode_texture(a, w):
    for k, (i, j) in (('stzw', (0, 4)), ('dstzw_dx', (2, 6)), ('dstzw_de', (8, 12)), ('dstzw_dy', (10, 14))):
        q = _quad(w, i, j)
        v = getattr(a, k)
        v[0], v[1], v[3] = q[0], q[1], q[2]


def decode_z(a, w):
    a.stzw[2] = s32(w[0])
    a.dstzw_dx[2] = s32(w[1])
    a.dstzw_de[2] = s32(w[2])
    a.dstzw_dy[2] = s32(w[3])


def normalize_dzpix(dz):
    if dz >= 0x8000:
        return 0x8000
    if dz == 0:
        return 1
    return 1 << (msb(dz) + 1)


def dz_compress_setup(dz):
    """the 4-bit DZ of a primitive (rdp_renderer.cpp dz_compress)"""
    v = 0
    if dz & 0xFF00: v |= 8
    if dz & 0xF0F0: v |= 4
    if dz & 0xCCCC: v |= 2
    if dz & 0xAAAA: v |= 1
    return v


def primitive_dz(attr, use_prim_depth, prim_dz):
    """(dz, dz_compressed): the depth slope the depth test uses"""
    if use_prim_depth:
        return prim_dz, dz_compress_setup(prim_dz)
    dzdx = attr.dstzw_dx[2] >> 16
    dzdy = attr.dstzw_dy[2] >> 16
    dzpix = ((~dzdx & 0x7FFF) if dzdx < 0 else dzdx) + ((~dzdy & 0x7FFF) if dzdy < 0 else dzdy)
    dzpix = normalize_dzpix(dzpix)
    return dzpix, dz_compress_setup(dzpix)


# --- stage: span setup (span_setup.comp) ----------------------------------------------------
def quantize_x(x):
    """s.15 to 1/8 pixel, sticky"""
    return (x >> 12) | (1 if x & 0xFFF else 0)


def span_setup(t, a, sc, y):
    """scanline y of a primitive: the attributes where the scanline's
    interpolation starts, and the four sub-scanlines' x extents (in 1/8 pixel,
    clamped to the scissor, 0xFFFF/0 where a sub-scanline is out)"""
    sp = Span()
    flip = t.flags & TRI_FLIP
    dy = y - (t.yh >> 2)
    xh = s32(t.xh + dy * (t.dxhdy << 2))
    if t.flags & TRI_DO_OFFSET:
        # varyings are latched at the last sub-scanline instead of the first
        xh = s32(xh + 3 * t.dxhdy)
        drgba_diff = []
        for i in range(4):
            deh = a.drgba_de[i] & ~0x1FF
            dyh = a.drgba_dy[i] & ~0x1FF
            drgba_diff.append(deh - (deh >> 2) - dyh + (dyh >> 2))
        dstzw_diff = []
        for i in range(4):
            deh = a.dstzw_de[i] & ~0x1FF
            dyh = a.dstzw_dy[i] & ~0x1FF
            dstzw_diff.append(deh - (deh >> 2) - dyh + (dyh >> 2))
    else:
        drgba_diff = dstzw_diff = (0, 0, 0, 0)
    base_x = xh >> 15
    xfrac = 0 if t.flags & TRI_SKIP_XFRAC else (xh >> 7) & 0xFF
    sp.rgba = [s32((((a.rgba[i] + dy * a.drgba_de[i]) & ~0x1FF) + drgba_diff[i]
                    - xfrac * ((a.drgba_dx[i] >> 8) & ~1)) & ~0x3FF) for i in range(4)]
    sp.stzw = [s32((((a.stzw[i] + dy * a.dstzw_de[i]) & ~0x1FF) + dstzw_diff[i]
                    - xfrac * ((a.dstzw_dx[i] >> 8) & ~1)) & ~0x3FF) for i in range(4)]
    sp.base_x = base_x

    yh_ib = t.yh & ~3
    ym_ib = t.ym
    ylo = max(t.yh, sc[1])
    yhi = min(t.yl, sc[3])
    lo_sc = sc[0] << 1
    hi_sc = sc[2] << 1
    xls, xrs, inv = [], [], []
    all_over = all_under = True
    for k in range(4):
        ys = y * 4 + k
        clip = ys < ylo or ys >= yhi
        xhk = sext(t.xh + (ys - yh_ib) * t.dxhdy, 27)
        if ys < t.ym:
            xlk = sext(t.xm + (ys - yh_ib) * t.dxmdy, 27)
        else:
            xlk = sext(t.xl + (ys - ym_ib) * t.dxldy, 27)
        hq, lq = quantize_x(xhk), quantize_x(xlk)
        xl_, xr_ = (hq, lq) if flip else (lq, hq)
        bad = (xl_ >> 1) > (xr_ >> 1)
        if min(xl_, xr_) < hi_sc:
            all_over = False
        if max(xl_, xr_) >= lo_sc:
            all_under = False
        xl_ = min(max(xl_, lo_sc), hi_sc)
        xr_ = min(max(xr_, lo_sc), hi_sc)
        bad = bad or clip
        if bad:
            xl_, xr_ = 0xFFFF, 0
        xls.append(xl_)
        xrs.append(xr_)
        inv.append(bad)
    sp.xleft = xls
    sp.xright = xrs
    sp.start_x = min(xls) >> 3
    sp.end_x = max(xrs) >> 3
    valid = not all(inv) and not all_over and not all_under
    if t.flags & TRI_INTERLACE_FIELD:
        if (y & 1) != (1 if t.flags & TRI_INTERLACE_KEEP_ODD else 0):
            valid = False
    sp.valid = valid
    sp.lodlength = sext((sp.end_x - base_x) if flip else (base_x - sp.start_x), 16)
    return sp


# --- stage: coverage (coverage.h) -------------------------------------------------------------
# sample k of a pixel: sub-scanline k >> 1, x offset in 1/8 pixel. Bit order is
# parallel-RDP's, so the first sample in scanline order is the lowest bit.
_COV_SAMPLES = ((0, 0), (0, 4), (1, 2), (1, 6), (2, 0), (2, 4), (3, 2), (3, 6))


def compute_coverage(xleft, xright, x):
    xs = x << 3
    cov = 0
    for bit, (k, off) in enumerate(_COV_SAMPLES):
        p = xs + off
        if xleft[k] <= p < xright[k]:
            cov |= 1 << bit
    return cov


def blend_coverage(coverage, memory_coverage, blend_en, mode):
    if mode == 0:                                   # clamp
        return min(7, memory_coverage + coverage) if blend_en else (coverage - 1) & 7
    if mode == 1:                                   # wrap
        return (coverage + memory_coverage) & 7
    if mode == 2:                                   # zap
        return 7
    return memory_coverage                          # save


# --- stage: attribute interpolation (interpolation.h, clamping.h) ----------------------------
def clamp_9bit(c):
    v = ((c + 0x80) & 0x1FF) - 0x80             # sext(c - 0x80, 9) + 0x80
    return 0 if v < 0 else 0xFF if v > 0xFF else v


def clamp_z(z):
    z = sext(z - (1 << 17), 19) + (1 << 17)
    return 0 if z < 0 else 0x3FFFF if z > 0x3FFFF else z


def _centroid(coverage):
    fc = lsb(coverage)
    yoff = fc >> 1
    xoff = ((fc & 1) << 1) + (yoff & 1)
    return xoff, yoff


def interpolate_rgba(rgba, drgba_dx, drgba_dy, dx, coverage):
    """shade at the pixel's first covered sample: 8-bit, clamped from 9"""
    xoff, yoff = _centroid(coverage)
    out = []
    for i in range(4):
        v = s32(rgba[i] + (drgba_dx[i] & ~0x1F) * dx)
        sn = v >> 14
        sn = ((sn << 2) + xoff * (drgba_dx[i] >> 14) + yoff * (drgba_dy[i] >> 14)) >> 4
        out.append(clamp_9bit(sn))
    return out


def no_perspective_divide(s, t, w):
    return s, t, False


# (rcp, slope) pairs for the reciprocal of w (perspective.h)
PERSP_TABLE = (
    (0x4000, -252 * 4), (0x3f04, -244 * 4), (0x3e10, -238 * 4), (0x3d22, -230 * 4),
    (0x3c3c, -223 * 4), (0x3b5d, -218 * 4), (0x3a83, -210 * 4), (0x39b1, -205 * 4),
    (0x38e4, -200 * 4), (0x381c, -194 * 4), (0x375a, -189 * 4), (0x369d, -184 * 4),
    (0x35e5, -179 * 4), (0x3532, -175 * 4), (0x3483, -170 * 4), (0x33d9, -166 * 4),
    (0x3333, -162 * 4), (0x3291, -157 * 4), (0x31f4, -155 * 4), (0x3159, -150 * 4),
    (0x30c3, -147 * 4), (0x3030, -143 * 4), (0x2fa1, -140 * 4), (0x2f15, -137 * 4),
    (0x2e8c, -134 * 4), (0x2e06, -131 * 4), (0x2d83, -128 * 4), (0x2d03, -125 * 4),
    (0x2c86, -123 * 4), (0x2c0b, -120 * 4), (0x2b93, -117 * 4), (0x2b1e, -115 * 4),
    (0x2aab, -113 * 4), (0x2a3a, -110 * 4), (0x29cc, -108 * 4), (0x2960, -106 * 4),
    (0x28f6, -104 * 4), (0x288e, -102 * 4), (0x2828, -100 * 4), (0x27c4, -98 * 4),
    (0x2762, -96 * 4), (0x2702, -94 * 4), (0x26a4, -92 * 4), (0x2648, -91 * 4),
    (0x25ed, -89 * 4), (0x2594, -87 * 4), (0x253d, -86 * 4), (0x24e7, -85 * 4),
    (0x2492, -83 * 4), (0x243f, -81 * 4), (0x23ee, -80 * 4), (0x239e, -79 * 4),
    (0x234f, -77 * 4), (0x2302, -76 * 4), (0x22b6, -74 * 4), (0x226c, -74 * 4),
    (0x2222, -72 * 4), (0x21da, -71 * 4), (0x2193, -70 * 4), (0x214d, -69 * 4),
    (0x2108, -67 * 4), (0x20c5, -67 * 4), (0x2082, -65 * 4), (0x2041, -65 * 4))


def perspective_divide(s, t, w):
    """(s, t) / w: s16 by s1.15 with a table reciprocal; 17-bit results and
    an overflow flag (perspective.h)"""
    overflow = False
    w_carry = w <= 0
    w &= 0x7FFF
    shift = min(14 - msb(w), 14)
    normout = (w << shift) & 0x3FFF
    wnorm = normout & 0xFF
    tx, ty = PERSP_TABLE[normout >> 8]
    rcp = ((ty * wnorm) >> 10) + tx
    temp_mask = ((1 << 30) - 1) & -((1 << 29) >> shift)
    out = []
    for c in (s, t):
        prod = c * rcp
        oob = prod & temp_mask
        if shift != 14:
            prod = prod >> (13 - shift)
            temp = prod
        else:
            temp = prod << 1
        if oob != temp_mask and oob != 0:
            temp = 0x7FFF if (prod & (1 << 29)) == 0 else -0x8000
            overflow = True
        out.append(temp)
    if w_carry:
        out = [0x7FFF, 0x7FFF]
        overflow = True
    s_, t_ = (max(-0x10000, min(0xFFFF, v)) for v in out)
    return s_, t_, overflow


def interpolate_stz(stzw, dstzw_dx, dstzw_dy, dx, coverage, perspective, uses_lod, direction):
    """(st, st_dx, st_dy, z, overflow): texture coordinates at the pixel and
    one pixel on in x and in y (for LOD), and the 18-bit z at the first
    covered sample"""
    s = s32(stzw[0] + (dstzw_dx[0] & ~0x1F) * dx)
    t = s32(stzw[1] + (dstzw_dx[1] & ~0x1F) * dx)
    w = s32(stzw[3] + (dstzw_dx[3] & ~0x1F) * dx)
    div = perspective_divide if perspective else no_perspective_divide
    ss, tt, ovf = div(s >> 16, t >> 16, w >> 16)
    st_dx = st_dy = None
    if uses_lod:
        sx = s32(s + direction * (dstzw_dx[0] & ~0x1F))
        tx = s32(t + direction * (dstzw_dx[1] & ~0x1F))
        wx = s32(w + direction * (dstzw_dx[3] & ~0x1F))
        sy = s32(s + (dstzw_dy[0] & ~0x7FFF))
        ty = s32(t + (dstzw_dy[1] & ~0x7FFF))
        wy = s32(w + (dstzw_dy[3] & ~0x7FFF))
        a, b, o1 = div(sx >> 16, tx >> 16, wx >> 16)
        c, d, o2 = div(sy >> 16, ty >> 16, wy >> 16)
        st_dx, st_dy = (a, b), (c, d)
        ovf = ovf or o1 or o2
    z = s32(stzw[2] + dstzw_dx[2] * dx)
    xoff, yoff = _centroid(coverage)
    sz = ((z >> 10) << 2) + xoff * (dstzw_dx[2] >> 10) + yoff * (dstzw_dy[2] >> 10)
    sz = s32(sz) >> 5
    return (ss, tt), st_dx, st_dy, clamp_z(sz), ovf


def interpolate_st_single(stzw, dstzw_dx, dx, perspective):
    s = s32(stzw[0] + (dstzw_dx[0] & ~0x1F) * dx) >> 16
    t = s32(stzw[1] + (dstzw_dx[1] & ~0x1F) * dx) >> 16
    w = s32(stzw[3] + (dstzw_dx[3] & ~0x1F) * dx) >> 16
    ss, tt, _ = (perspective_divide if perspective else no_perspective_divide)(s, t, w)
    return ss, tt


def interpolate_st_copy(sp, dstzw_dx, x, perspective, flip, dx_mask, dx_shift):
    """copy mode: s, t once per 64-bit word of framebuffer, and the pixel's
    offset within the word"""
    dx = (x - sp.start_x) if flip else (sp.end_x - x)
    s_offset = dx - (dx & dx_mask)
    lerp_dx = (dx >> dx_shift) * (1 if flip else -1)
    s = s32(sp.stzw[0] + (dstzw_dx[0] & ~0x1F) * lerp_dx) >> 16
    t = s32(sp.stzw[1] + (dstzw_dx[1] & ~0x1F) * lerp_dx) >> 16
    w = s32(sp.stzw[3] + (dstzw_dx[3] & ~0x1F) * lerp_dx) >> 16
    ss, tt, _ = (perspective_divide if perspective else no_perspective_divide)(s, t, w)
    return ss, tt, s_offset


# --- stage: LOD (texture.h compute_lod_2cycle) ---------------------------------------------
def compute_lod(tile0, tile1, max_level, min_lod, st, st_dx, st_dy, overflow, tex_lod_en, sharpen, detail):
    """-> (tile0, tile1, lod_frac)"""
    magnify = distant = False
    tile_offset = 0
    if overflow:
        distant = True
        lod_frac = 0xFF
    else:
        d = []
        for a, b in ((st_dx[0], st[0]), (st_dx[1], st[1]), (st_dy[0], st[0]), (st_dy[1], st[1])):
            v = a - b
            d.append(v ^ (v >> 31))
        max_d = max(d)
        if max_d >= 0x4000:
            distant = True
            lod_frac = 0xFF
            tile_offset = max_level
        elif max_d < 32:
            distant = max_level == 0
            magnify = True
            if not sharpen and not detail:
                lod_frac = 0xFF if distant else 0
            else:
                lod_frac = (max(min_lod, max_d) << 3) + (-0x100 if sharpen else 0)
        else:
            mip_base = max(msb(max_d >> 5), 0)
            distant = mip_base >= max_level
            if distant and not sharpen and not detail:
                lod_frac = 0xFF
            else:
                lod_frac = ((max_d << 3) >> mip_base) & 0xFF
                tile_offset = mip_base
    if tex_lod_en:
        if distant:
            tile_offset = max_level
        if not detail:
            tile0 = (tile0 + tile_offset) & 7
            if distant or (not sharpen and magnify):
                tile1 = tile0
            else:
                tile1 = (tile0 + 1) & 7
        else:
            tile1 = (tile0 + tile_offset + (1 if (distant or magnify) else 2)) & 7
            tile0 = (tile0 + tile_offset + (0 if magnify else 1)) & 7
    return tile0, tile1, sext(lod_frac, 16)


# --- stage: texel fetch (texture.h) ----------------------------------------------------------
# TMEM is 2048 16-bit words, by their big-endian address (word i is bytes 2i, 2i+1).
# Odd lines are stored with their 32-bit halves swapped: the byte address of a
# texel on line t is xored with (t & 1) << 2.

def _tbyte(tm, b):
    w = tm[b >> 1]
    return w & 0xFF if b & 1 else w >> 8


def convert_rgba16(word):
    r = (word >> 11) & 31
    g = (word >> 6) & 31
    b = (word >> 1) & 31
    return ((r << 3) | (r >> 2), (g << 3) | (g >> 2), (b << 3) | (b >> 2), (word & 1) * 0xFF)


def convert_ia16(word):
    i = word >> 8
    return (i, i, i, word & 0xFF)


def _byte_index(tile, s_bytes, t, mask):
    return ((tile.offset + tile.stride * t + s_bytes) & mask) ^ ((t & 1) << 2)


def texel_rgba4(tm, tile, s, t):
    v = (_tbyte(tm, _byte_index(tile, s >> 1, t, 0xFFF)) >> ((~s & 1) * 4)) & 0xF
    v |= v << 4
    return (v, v, v, v)


def texel_ia4(tm, tile, s, t):
    v = (_tbyte(tm, _byte_index(tile, s >> 1, t, 0xFFF)) >> ((~s & 1) * 4)) & 0xF
    i = v & 0xE
    i = (i << 4) | (i << 1) | (i >> 2)
    return (i, i, i, (v & 1) * 0xFF)


def texel_ci4(tm, tile, s, t):
    v = (_tbyte(tm, _byte_index(tile, s >> 1, t, 0xFFF)) >> ((~s & 1) * 4)) & 0xF
    v |= tile.palette << 4
    return (v, v, v, v)


def _tlut(tm, entry, tlut_type):
    word = tm[0x400 | entry]
    return convert_ia16(word) if tlut_type else convert_rgba16(word)


def texel_ci4_tlut(tm, tile, s, t, lut_offset, addr_xor, tlut_type):
    v = (_tbyte(tm, _byte_index(tile, s >> 1, t, 0x7FF)) >> ((~s & 1) * 4)) & 0xF
    v |= tile.palette << 4
    return _tlut(tm, ((v << 2) + lut_offset) ^ addr_xor ^ 1, tlut_type)


def texel_ci8_tlut(tm, tile, s, t, lut_offset, addr_xor, tlut_type):
    v = _tbyte(tm, _byte_index(tile, s, t, 0x7FF))
    return _tlut(tm, ((v << 2) + lut_offset) ^ addr_xor ^ 1, tlut_type)


def _word_index(tile, s, t, mask):
    return (((tile.offset + tile.stride * t + s * 2) & mask) >> 1) ^ ((t & 1) << 1)


def texel_ci32(tm, tile, s, t):
    w = tm[_word_index(tile, s, t, 0xFFF)]
    return (w >> 8, w & 0xFF, w >> 8, w & 0xFF)


def texel_ci32_tlut(tm, tile, s, t, lut_offset, addr_xor, tlut_type):
    w = tm[_word_index(tile, s, t, 0x7FF)]
    return _tlut(tm, (((w >> 6) & ~3) + lut_offset) ^ addr_xor ^ 1, tlut_type)


def texel_rgba8(tm, tile, s, t):
    v = _tbyte(tm, _byte_index(tile, s, t, 0xFFF))
    return (v, v, v, v)


def texel_ia8(tm, tile, s, t):
    v = _tbyte(tm, _byte_index(tile, s, t, 0xFFF))
    i = v >> 4
    a = v & 0xF
    return (i | (i << 4),) * 3 + (a | (a << 4),)


def texel_yuv16(tm, tile, s, t, chroma_x):
    base = tile.offset + tile.stride * t
    luma = _tbyte(tm, (((base + s) & 0x7FF) ^ ((t & 1) << 2)) | 0x800)
    chroma = tm[(((base + chroma_x * 2) & 0x7FF) >> 1) ^ ((t & 1) << 1)]
    return ((chroma >> 8) - 0x80, (chroma & 0xFF) - 0x80, luma, luma)


def texel_rgba16(tm, tile, s, t):
    return convert_rgba16(tm[_word_index(tile, s, t, 0xFFF)])


def texel_ia16(tm, tile, s, t):
    return convert_ia16(tm[_word_index(tile, s, t, 0xFFF)])


def texel_rgba32(tm, tile, s, t):
    i = _word_index(tile, s, t, 0x7FF)
    lo, hi = tm[i], tm[i | 0x400]
    return (lo >> 8, lo & 0xFF, hi >> 8, hi & 0xFF)


def texel_fetch_fn(fmt, size):
    """the plain (non-TLUT) texel fetch for a tile's format and size"""
    if fmt == FMT_RGBA:
        return (texel_rgba4, texel_rgba8, texel_rgba16, texel_rgba32)[size]
    if fmt == FMT_CI:
        return (texel_ci4, texel_rgba8, texel_ci32, texel_ci32)[size]
    if fmt == FMT_IA:
        return (texel_ia4, texel_ia8, texel_ia16, texel_ci32)[size]
    if fmt == FMT_I:
        return (texel_rgba4, texel_rgba8, texel_ci32, texel_ci32)[size]
    # YUV is handled separately; the other format codes (5..7) are I's
    return (texel_rgba4, texel_rgba8, texel_ci32, texel_ci32)[size]


def texel_mask_s(tile, s):
    if tile.mask_s:
        mask = 1 << tile.mask_s
        if tile.flags & TILE_MIRROR_S:
            s ^= max((s & mask) - 1, 0)
        s &= mask - 1
    return s


def texel_mask_t(tile, t):
    if tile.mask_t:
        mask = 1 << tile.mask_t
        if tile.flags & TILE_MIRROR_T:
            t ^= max((t & mask) - 1, 0)
        t &= mask - 1
    return t


def _shift(coord, shift):
    coord = max(-0x8000, min(0x7FFF, coord))
    if shift < 11:
        return coord >> shift
    return s32(coord << (32 - shift)) >> 16


def clamp_and_shift_coord(clamp_bit, coord, lo, hi, shift):
    """s10.5 coordinate: shifted, made relative to the tile and clamped"""
    coord = _shift(coord, shift)
    if clamp_bit:
        if (coord >> 3) >= hi:
            return (((hi >> 2) - (lo >> 2)) & 0x3FF) << 5
        return max(coord - (lo << 3), 0)
    return coord - (lo << 3)


def shift_coord(coord, lo, shift):
    return _shift(coord, shift) - (lo << 3)


def texture_convert_factors(texel, factors):
    """YUV to RGB (SET_CONVERT's K0..K3): the texel's R, G, B are U, V, Y"""
    u, v, y = sext(texel[0], 9), sext(texel[1], 9), sext(texel[2], 9)
    r = y + ((factors[0] * v + 0x80) >> 8)
    g = y + ((factors[1] * u + factors[2] * v + 0x80) >> 8)
    b = y + ((factors[3] * u + 0x80) >> 8)
    return (r, g, b, y)


def bilinear_3tap(t00, t10, t01, t11, fx, fy):
    if fx + fy >= 32:
        base, ffx, ffy = t11, 32 - fy, 32 - fx
    else:
        base, ffx, ffy = t00, fx, fy
    return tuple((((t10[i] - base[i]) * ffx + (t01[i] - base[i]) * ffy + 0x10) >> 5) + base[i]
                 for i in range(len(base)))


_Z4 = (0, 0, 0, 0)


def sample_texture(tm, tile, st, tlut, tlut_type, sample_quad, mid_texel_state, convert_one, bilerp,
                   factors, prev_cycle):
    """a texel of a tile at (s, t) (s10.5): wrap, mirror and clamp, the fetch
    of up to four texels, the filter (point, 3-tap bilinear, mid-texel average,
    YUV) or colour conversion"""
    s = clamp_and_shift_coord(tile.flags & TILE_CLAMP_S, st[0], tile.slo, tile.shi, tile.shift_s)
    t = clamp_and_shift_coord(tile.flags & TILE_CLAMP_T, st[1], tile.tlo, tile.thi, tile.shift_t)
    if sample_quad or tlut:
        fx, fy = s & 31, t & 31
    else:
        fx = fy = 0
    sum_frac = fx + fy
    s >>= 5
    t >>= 5
    s0 = texel_mask_s(tile, s)
    t0 = texel_mask_t(tile, t)
    s1 = texel_mask_s(tile, s + 1)
    t1 = texel_mask_t(tile, t + 1)
    tdiff = max(t1 - t0, -255)
    t1 = (t0 & 0xFF) + tdiff
    t0 &= 0xFF

    mid_texel = mid_texel_state and bilerp and fx == 0x10 and fy == 0x10
    upper_lut = sum_frac >= 0x20
    if mid_texel:
        sum_frac = 0
    yuv = tile.fmt == FMT_YUV
    if sum_frac >= 0x20:
        bs, bt = s1, t1
    else:
        bs, bt = s0, t0
    chroma_frac = ((s0 & 1) << 4) | (fx >> 1)
    t_base = t10 = t01 = t11 = _Z4

    if tlut:
        if not sample_quad:
            bs, bt = s0, t0
            s1, t1 = s0, t0
        upper = sum_frac >= 0x20
        addr_xor = 2 if upper_lut else 1
        if tile.size == 0:
            f = lambda ss, tt, off: texel_ci4_tlut(tm, tile, ss, tt, off, addr_xor, tlut_type)
        elif tile.size == 1:
            f = lambda ss, tt, off: texel_ci8_tlut(tm, tile, ss, tt, off, addr_xor, tlut_type)
        else:
            f = lambda ss, tt, off: texel_ci32_tlut(tm, tile, ss, tt, off, addr_xor, tlut_type)
        t_base = f(bs, bt, 3 if upper else 0)
        if bilerp:
            t10 = f(s1, t0, 1)
            t01 = f(s0, t1, 2)
        if mid_texel:
            t11 = f(s1, t1, 3)
    elif yuv:
        cx0 = s0 >> 1
        cx1 = (s1 + (s1 - s0)) >> 1
        t_base = texel_yuv16(tm, tile, s0, t0, cx0)
        if sample_quad:
            t10 = texel_yuv16(tm, tile, s1, t0, cx1)
            t01 = texel_yuv16(tm, tile, s0, t1, cx0)
            t11 = texel_yuv16(tm, tile, s1, t1, cx1)
    else:
        f = texel_fetch_fn(tile.fmt, tile.size)
        t_base = f(tm, tile, bs, bt)
        if sample_quad:
            t10 = f(tm, tile, s1, t0)
            t01 = f(tm, tile, s0, t1)
        if mid_texel:
            t11 = f(tm, tile, s1, t1)

    if convert_one:
        prev = [sext(v, 9) for v in prev_cycle]
        if sample_quad:
            mid_rg = (mid_texel_state and chroma_frac == 0x10 and fy == 0x10) if yuv else mid_texel
            mid_ba = mid_texel
            upper_ba = sum_frac >= 32
            upper_rg = ((chroma_frac + fy) >= 32 and not mid_rg) if yuv else upper_ba
            frg = (prev[1], prev[0]) if upper_rg else (prev[0], prev[1])
            fba = (prev[1], prev[0]) if upper_ba else (prev[0], prev[1])
            out = []
            for i in range(4):
                fr = frg if i < 2 else fba
                mid = mid_rg if i < 2 else mid_ba
                up = upper_rg if i < 2 else upper_ba
                if mid:
                    v = (fr[0] * (t01[i] - t11[i]) + fr[1] * (t10[i] - t11[i]) + ((t_base[i] - t11[i]) << 6) + 0x80)
                else:
                    base = t11[i] if (up and yuv) else t_base[i]
                    v = fr[0] * (t10[i] - base) + fr[1] * (t01[i] - base) + 0x80
                out.append((v >> 8) + prev[2])
            accum = tuple(out)
        else:
            accum = (prev[2],) * 4
    elif yuv:
        if sample_quad:
            if bilerp:
                if mid_texel_state and chroma_frac == 0x10 and fy == 0x10:
                    chroma = tuple((t_base[i] + t10[i] + t11[i] + t01[i] + 2) >> 2 for i in (0, 1))
                else:
                    chroma = bilinear_3tap(t_base[:2], t10[:2], t01[:2], t11[:2], chroma_frac, fy)
                if mid_texel:
                    luma = tuple((t_base[i] + t10[i] + t11[i] + t01[i] + 2) >> 2 for i in (2, 3))
                else:
                    luma = bilinear_3tap(t_base[2:], t10[2:], t01[2:], t11[2:], fx, fy)
            else:
                luma = t11[2:] if fx + fy >= 32 else t_base[2:]
                chroma = t11[:2] if chroma_frac + fy >= 32 else t_base[:2]
            accum = tuple(chroma) + tuple(luma)
        else:
            accum = t_base
    elif mid_texel:
        accum = tuple((t_base[i] + t01[i] + t10[i] + t11[i] + 2) >> 2 for i in range(4))
    elif bilerp and (sample_quad or tlut):
        if sum_frac >= 32:
            ffx, ffy = 32 - fy, 32 - fx
        else:
            ffx, ffy = fx, fy
        accum = tuple((((t10[i] - t_base[i]) * ffx + (t01[i] - t_base[i]) * ffy + 0x10) >> 5) + t_base[i]
                      for i in range(4))
    else:
        accum = t_base
    if not bilerp and not convert_one:
        accum = texture_convert_factors(accum, factors)
    # (i16 in parallel-RDP: every path above stays within +-2^11, so no wrap)
    return accum


# --- copy mode texel fetch (texture.h sample_texture_copy) ------------------------------------
def texel_mask_s_copy(tile, s):
    out = []
    for v in (s, s + 1):
        if tile.mask_s:
            mask = 1 << tile.mask_s
            if tile.flags & TILE_MIRROR_S:
                v ^= max((v & mask) - 1, 0)
            v &= mask - 1
        out.append(v)
    return out


def sample_texture_copy_word(tm, tile, s, t, s_offset, tlut):
    """the 16-bit word the copy pipe reads for one pixel"""
    high_word = s_offset < 2
    replicate_8bpp = high_word and tile.size != 2 and not tlut
    s_shamt = min(tile.size, 2)
    idx_mask = 0x3FF if (tile.size == 3 or tlut) else 0x7FF
    if replicate_8bpp:
        s += 2 * s_offset
        ss = texel_mask_s_copy(tile, s)
        tt = texel_mask_t(tile, t)
        tbase = tile.offset + tile.stride * tt
        samp = []
        for sv in ss:
            nib = ((tbase * 2 + (sv << s_shamt)) & 0x1FFF) ^ ((tt & 1) * 8)
            v = tm[(nib >> 2) & idx_mask]
            if tile.size == 1:
                v = (v >> (8 - 4 * (nib & 2))) & 0xFF
            elif tile.size == 0:
                v = ((v >> (12 - 4 * (nib & 3))) & 0xF) * 0x11
            else:
                v >>= 8
            samp.append(v)
        return (samp[0] << 8) | samp[1]
    s += s_offset
    sv = texel_mask_s(tile, s)
    tt = texel_mask_t(tile, t)
    tbase = tile.offset + tile.stride * tt
    nib = ((tbase * 2 + (sv << s_shamt)) & 0x1FFF) ^ ((tt & 1) * 8)
    v = tm[(nib >> 2) & idx_mask]
    if tlut:
        if tile.size == 0:
            v = (v >> (12 - 4 * (nib & 3))) & 0xF
            v |= tile.palette << 4
        else:
            v = (v >> (8 - 4 * (nib & 2))) & 0xFF
        v = (v << 2) + s_offset
        v = tm[(v | 0x400) & 0x7FF]
    return v


def sample_texture_copy(tm, tile, s, t, s_offset, tlut, fb_size):
    s = shift_coord(s, tile.slo, tile.shift_s) >> 5
    t = shift_coord(t, tile.tlo, tile.shift_t) >> 5
    if fb_size == 0:
        return 0
    if fb_size == 1:
        v = sample_texture_copy_word(tm, tile, s, t, s_offset >> 1, tlut)
        if tlut:
            # parallel-RDP takes the entry's bytes in turn; krom's InternalPalette
            # screenshot shows hardware writing the high byte to every pixel
            return (v >> 8) & 0xFF
        return (v >> (8 - 8 * (s_offset & 1))) & 0xFF
    return sample_texture_copy_word(tm, tile, s, t, s_offset, tlut)


# --- stage: noise and dither (noise.h, dither.h) ----------------------------------------------
NOISE_PRIME = 1103515245


def reseed_noise(x, y, prim):
    a, b, c = x & M32, y & M32, prim & M32
    for _ in range(3):
        a, b, c = (((a >> 8) ^ b) * NOISE_PRIME) & M32, (((b >> 8) ^ c) * NOISE_PRIME) & M32, \
                  (((c >> 8) ^ a) * NOISE_PRIME) & M32
    return a >> 16


DITHER_MATRICES = ((0, 6, 1, 7, 4, 2, 5, 3, 3, 5, 2, 4, 7, 1, 6, 0),
                   (0, 4, 1, 5, 4, 0, 5, 1, 3, 7, 2, 6, 7, 3, 6, 2))


def dither_coefficients(x, y, mode_rgb, mode_alpha, noise):
    """(rgb_dither: three 3-bit thresholds, alpha_dither: 3 bits)"""
    if mode_rgb < 2:
        rgb = DITHER_MATRICES[mode_rgb][(y & 3) * 4 + (x & 3)] * 0x49
    elif mode_rgb == 2:
        rgb = noise & 0x1FF
    else:
        rgb = 0
    if mode_alpha == 3:
        alpha = 0
    elif mode_alpha == 2:
        alpha = noise & 7
    else:
        alpha = DITHER_MATRICES[mode_rgb & 1][(y & 3) * 4 + (x & 3)] if mode_rgb >= 2 else (rgb & 7)
        if mode_alpha == 1:
            alpha = ~alpha & 7
    return rgb, alpha


def rgb_dither(rgb, dith):
    out = []
    for i, c in enumerate(rgb):
        d = (dith >> (3 * i)) & 7
        up = 255 if c > 247 else (c & 0xF8) + 8
        out.append((up if d < (c & 7) else c) & 0xFF)
    return out


# --- stage: colour combiner (combiner.h) -------------------------------------------------------
def special_expand(v):
    return ((v + 0x80) & 0x1FF) - 0x80           # sext(v - 0x80, 9) + 0x80


def combiner_equation(a, b, c, d):
    """(A - B) * C + D on one channel, 9-bit inputs, an unclamped result"""
    c = ((c + 0x100) & 0x1FF) - 0x100            # sext(c, 9)
    return ((((((a + 0x80) & 0x1FF) - ((b + 0x80) & 0x1FF)) * c) + 0x80) >> 8) + ((d + 0x80) & 0x1FF) - 0x80


class CombinerInputs:
    __slots__ = ('combined', 'texel0', 'texel1', 'shade', 'lod_frac', 'noise')


def _sel_rgb_a(sel, k, I):
    if sel == 0: return I.combined[:3]
    if sel == 1: return I.texel0[:3]
    if sel == 2: return I.texel1[:3]
    if sel == 4: return I.shade[:3]
    if sel == 6: return (0x100, 0x100, 0x100)
    if sel == 7: return (I.noise,) * 3
    return k                            # PRIM, ENV or zero, resolved at setup


def _sel_rgb_b(sel, k, I):
    if sel == 0: return I.combined[:3]
    if sel == 1: return I.texel0[:3]
    if sel == 2: return I.texel1[:3]
    if sel == 4: return I.shade[:3]
    return k                            # PRIM, ENV, key centre, K4 or zero


def _sel_rgb_c(sel, k, I):
    if sel == 0: return I.combined[:3]
    if sel == 1: return I.texel0[:3]
    if sel == 2: return I.texel1[:3]
    if sel == 4: return I.shade[:3]
    if sel == 7: return (I.combined[3],) * 3
    if sel == 8: return (I.texel0[3],) * 3
    if sel == 9: return (I.texel1[3],) * 3
    if sel == 11: return (I.shade[3],) * 3
    if sel == 13: return (I.lod_frac,) * 3
    return k                            # PRIM, ENV, key scale, their alphas, prim LOD, K5 or zero


def _sel_rgb_d(sel, k, I):
    if sel == 0: return I.combined[:3]
    if sel == 1: return I.texel0[:3]
    if sel == 2: return I.texel1[:3]
    if sel == 4: return I.shade[:3]
    if sel == 6: return (0x100, 0x100, 0x100)
    return k


def _sel_alpha_abd(sel, k, I):
    if sel == 0: return I.combined[3]
    if sel == 1: return I.texel0[3]
    if sel == 2: return I.texel1[3]
    if sel == 4: return I.shade[3]
    if sel == 6: return 0x100
    return k


def _sel_alpha_c(sel, k, I):
    if sel == 0: return I.lod_frac
    if sel == 1: return I.texel0[3]
    if sel == 2: return I.texel1[3]
    if sel == 4: return I.shade[3]
    return k


def combiner_constants(sel, prim, env, key_center, key_scale, convert, prim_lod_frac):
    """the constant each selector of a cycle reads (what parallel-RDP puts in
    DerivedSetup): sel = (rgb a, b, c, d, alpha a, b, c, d)"""
    ra, rb, rc, rd, aa, ab, ac, ad = sel
    rgb = lambda c: ((c >> 24) & 0xFF, (c >> 16) & 0xFF, (c >> 8) & 0xFF)
    z3 = (0, 0, 0)
    ka = rgb(prim) if ra == 3 else rgb(env) if ra == 5 else z3
    if rb == 3: kb = rgb(prim)
    elif rb == 5: kb = rgb(env)
    elif rb == 6: kb = tuple(key_center)
    elif rb == 7: kb = (convert[4],) * 3
    else: kb = z3
    if rc == 3: kc = rgb(prim)
    elif rc == 5: kc = rgb(env)
    elif rc == 6: kc = tuple(key_scale)
    elif rc == 10: kc = (prim & 0xFF,) * 3
    elif rc == 12: kc = (env & 0xFF,) * 3
    elif rc == 14: kc = (prim_lod_frac,) * 3
    elif rc == 15: kc = (convert[5],) * 3
    else: kc = z3
    kd = rgb(prim) if rd == 3 else rgb(env) if rd == 5 else z3
    al = lambda s: (prim & 0xFF) if s == 3 else (env & 0xFF) if s == 5 else 0
    kaa, kab, kad = al(aa), al(ab), al(ad)
    kac = (prim & 0xFF) if ac == 3 else (env & 0xFF) if ac == 5 else prim_lod_frac if ac == 6 else 0
    return (ka, kb, kc, kd, kaa, kab, kac, kad)


def combiner_raw(sel, k, I):
    """one cycle's equation on all four channels, unclamped"""
    a = _sel_rgb_a(sel[0], k[0], I)
    b = _sel_rgb_b(sel[1], k[1], I)
    c = _sel_rgb_c(sel[2], k[2], I)
    d = _sel_rgb_d(sel[3], k[3], I)
    out = [combiner_equation(a[i], b[i], c[i], d[i]) for i in range(3)]
    out.append(combiner_equation(_sel_alpha_abd(sel[4], k[4], I), _sel_alpha_abd(sel[5], k[5], I),
                                 _sel_alpha_c(sel[6], k[6], I), _sel_alpha_abd(sel[7], k[7], I)))
    return out


def combiner_cycle0(sel, k, I, alpha_dith, coverage, cvg_times_alpha, alpha_cvg_select, alpha_test):
    """-> (combined, unclamped, for cycle 1; alpha_test_reference)"""
    combined = combiner_raw(sel, k, I)
    ref = 0
    if alpha_test:
        ca = clamp_9bit(combined[3])
        ea = ca + ((ca + 1) >> 8)
        if alpha_cvg_select:
            ea = ((ea * coverage + 4) >> 3) if cvg_times_alpha else coverage << 5
        else:
            ea += alpha_dith
        ref = max(0, min(0xFF, ea))
    return combined, ref


def combiner_cycle1(sel, k, I, alpha_dith, coverage, cvg_times_alpha, alpha_cvg_select):
    """-> (combined: 8-bit RGBA, coverage) -- coverage is changed by cvg_times_alpha"""
    c = [clamp_9bit(v) for v in combiner_raw(sel, k, I)]
    ea = c[3] + ((c[3] + 1) >> 8)
    if cvg_times_alpha:
        mod = (ea * coverage + 4) >> 3
        coverage = mod >> 5
    else:
        mod = coverage << 5
    if alpha_cvg_select:
        ea = mod
    else:
        ea += alpha_dith
    c[3] = max(0, min(0xFF, ea))
    return c, coverage


# --- stage: depth (z_encode.h, depth_test.h) ---------------------------------------------------
def z_decompress(z):
    exponent = z >> 11
    mantissa = z & 0x7FF
    shift = max(6 - exponent, 0)
    return (mantissa << shift) + (0x40000 - (0x40000 >> exponent))


def z_compress(z):
    inv_z = max(0x3FFFF - z, 1)
    exponent = max(0, min(7, 17 - msb(inv_z)))
    shift = max(6 - exponent, 0)
    return ((exponent << 11) + ((z >> shift) & 0x7FF)) & 0xFFFF


def depth_test(z, dz, dz_compressed, mem_depth, mem_dz, coverage_count, mem_coverage,
               z_compare, z_mode, force_blend, aa_enable):
    """-> (pass, coverage_count, blend_en, coverage_wrap, (blend_shift_a, blend_shift_b))"""
    if z_compare:
        memory_z = z_decompress(mem_depth)
        memory_dz = 1 << mem_dz
        precision = (mem_depth >> 11) & 0xF
        coplanar = False
        shift_a = max(0, min(4, dz_compressed - mem_dz))
        shift_b = max(0, min(4, mem_dz - dz_compressed))
        if precision < 3:
            if memory_dz != 0x8000:
                memory_dz = max(memory_dz << 1, 16 >> precision)
            else:
                coplanar = True
                memory_dz = 0xFFFF
        cdz = dz | memory_dz
        combined_dz = (1 << msb(cdz)) if cdz else 0
        combined_dz_ip = combined_dz
        combined_dz <<= 3
        farther = coplanar or (z + combined_dz) >= memory_z
        overflow = (coverage_count + mem_coverage) >= 8
        blend_en = force_blend or (not overflow and aa_enable and farther)
        coverage_wrap = overflow
        max_z = memory_z == 0x3FFFF
        front = z < memory_z
        nearer = coplanar or (z - combined_dz) <= memory_z
        if z_mode == 0:                                       # opaque
            ok = max_z or (front if overflow else nearer)
        elif z_mode == 1:                                     # interpenetrating
            if not front or not farther or not overflow:
                ok = max_z or (front if overflow else nearer)
            else:
                sh = max(msb(combined_dz_ip & 0xFFFF), 0)
                cvg_coeff = ((memory_z >> sh) - (z >> sh)) & 0xF
                coverage_count = min((cvg_coeff * coverage_count) >> 3, 8)
                ok = True
        elif z_mode == 2:                                     # transparent
            ok = front or max_z
        else:                                                 # decal
            ok = farther and nearer and not max_z
        return ok, coverage_count, blend_en, coverage_wrap, (shift_a, shift_b)
    overflow = (coverage_count + mem_coverage) >= 8
    return (True, coverage_count, force_blend or (not overflow and aa_enable), overflow,
            (0, min(0xF - dz_compressed, 4)))


# --- stage: blender (blender.h) --------------------------------------------------------------
def blender(pixel, memory, fog, blend_col, shade_alpha, modes, force_blend, blend_en,
            color_on_coverage, coverage_wrap, blend_shift, final_cycle):
    """one blender cycle: modes = (1a, 1b, 2a, 2b); -> rgb"""
    srcs = (pixel, memory, blend_col, fog)
    rgb1 = srcs[modes[2]][:3]
    if final_cycle and color_on_coverage and not coverage_wrap:
        return list(rgb1)
    rgb0 = srcs[modes[0]][:3]
    if final_cycle:
        if not blend_en or (modes[1] == 0 and modes[3] == 0 and pixel[3] == 0xFF):
            return list(rgb0)
    a0 = (pixel[3], fog[3], shade_alpha, 0)[modes[1]]
    a1 = (~a0 & 0xFF, memory[3], 0xFF, 0)[modes[3]]
    a0 >>= 3
    a1 >>= 3
    if modes[3] == 1:
        a0 = (a0 >> blend_shift[0]) & 0x3C
        a1 = (a1 >> blend_shift[1]) | 3
    blended = [rgb0[i] * a0 + rgb1[i] * (a1 + 1) for i in range(3)]
    if not final_cycle or force_blend:
        return [(v >> 5) & 0xFF for v in blended]
    blend_sum = (a0 >> 2) + (a1 >> 2) + 1
    return [BLENDER_LUT[(blend_sum << 11) | ((v >> 2) & 0x7FF)] for v in blended]


# --- the framebuffer (memory_interfacing.h) ----------------------------------------------------
# RDRAM is the model's big-endian bytearray; the ninth bits ("hidden" RDRAM) are
# a separate bytearray of two bits per 16-bit word, as parallel-RDP keeps them.

def load_color(fmt, rd, hidden, index):
    """-> [r, g, b, a] as the blender sees memory (a holds the coverage in bits 5-7)"""
    if fmt == FB_I4 or fmt == FB_I8:
        index &= len(rd) - 1
        v = rd[index]
        return [v, v, v, hidden[index >> 1]]
    if fmt == FB_RGBA5551:
        index &= (len(rd) >> 1) - 1
        w = (rd[2 * index] << 8) | rd[2 * index + 1]
        return [(w >> 8) & 0xF8, (w >> 3) & 0xF8, (w << 2) & 0xF8, (hidden[index] << 5) | ((w & 1) << 7)]
    if fmt == FB_IA88:
        index &= (len(rd) >> 1) - 1
        w = (rd[2 * index] << 8) | rd[2 * index + 1]
        return [w >> 8, w >> 8, w >> 8, w & 0xFF]
    index &= (len(rd) >> 2) - 1
    p = 4 * index
    return [rd[p], rd[p + 1], rd[p + 2], rd[p + 3]]


def store_color(fmt, rd, hidden, index, c):
    if fmt == FB_I4:
        index &= len(rd) - 1
        rd[index] = 0
        if index & 1:
            hidden[index >> 1] = c[3] & 0xFF
    elif fmt == FB_I8:
        index &= len(rd) - 1
        col = c[1] if index & 1 else c[0]
        rd[index] = col
        if index & 1:
            hidden[index >> 1] = (col & 1) * 3
    elif fmt == FB_RGBA5551:
        index &= (len(rd) >> 1) - 1
        cov = c[3] >> 5
        w = ((c[0] & 0xF8) << 8) | ((c[1] & 0xF8) << 3) | ((c[2] & 0xF8) >> 2) | (cov >> 2)
        rd[2 * index] = w >> 8
        rd[2 * index + 1] = w & 0xFF
        hidden[index] = cov & 3
    elif fmt == FB_IA88:
        index &= (len(rd) >> 1) - 1
        rd[2 * index] = c[0]
        rd[2 * index + 1] = c[3]
        hidden[index] = (c[3] & 1) * 3
    else:
        index &= (len(rd) >> 2) - 1
        p = 4 * index
        rd[p:p + 4] = bytes(c)
        hidden[2 * index] = (c[1] & 1) * 3
        hidden[2 * index + 1] = (c[3] & 1) * 3


def load_depth(rd, hidden, index):
    """-> (14-bit compressed z, 4-bit dz)"""
    index &= (len(rd) >> 1) - 1
    w = (rd[2 * index] << 8) | rd[2 * index + 1]
    return w >> 2, hidden[index] | ((w & 3) << 2)


def store_depth(rd, hidden, index, depth, dz):
    index &= (len(rd) >> 1) - 1
    w = ((depth << 2) | (dz >> 2)) & 0xFFFF
    rd[2 * index] = w >> 8
    rd[2 * index + 1] = w & 0xFF
    hidden[index] = dz & 3


def decode_memory_color(fmt, c, image_read_en):
    cov = (c[3] & 0xE0) if image_read_en else 0xE0
    if fmt == FB_I4:
        return [0, 0, 0, 0xE0]
    if fmt == FB_I8:
        return [c[0], c[0], c[0], 0xE0]
    if fmt == FB_RGBA5551:
        return [c[0] & 0xF8, c[1] & 0xF8, c[2] & 0xF8, cov]
    if fmt == FB_IA88:
        return [c[0], c[0], c[0], cov]
    return [c[0], c[1], c[2], cov]


def fill_pixel_color(fmt, fill, index):
    """the colour FILL mode writes at a framebuffer index"""
    if fmt == FB_RGBA8888:
        return [(fill >> 24) & 0xFF, (fill >> 16) & 0xFF, (fill >> 8) & 0xFF, fill & 0xFF]
    if fmt == FB_RGBA5551:
        c = (fill >> (((index & 1) ^ 1) * 16)) & M32
        return [(c >> 8) & 0xF8, (c >> 3) & 0xF8, (c << 2) & 0xF8, (c & 1) * 0xE0]
    if fmt == FB_IA88:
        c = (fill >> (((index & 1) ^ 1) * 16)) & 0xFFFF
        return [(c >> 8) & 0xFF, (c >> 8) & 0xFF, (c >> 8) & 0xFF, c & 0xFF]
    if fmt == FB_I8:
        c = (fill >> (((index & 3) ^ 3) * 8)) & 0xFF
        return [c, c, c, c]
    return None                                  # 4-bit: no fill


def copy_pixel_color(fmt, word):
    """the colour COPY mode writes, from the texel word"""
    if fmt == FB_I4:
        return [0, 0, 0, 0]
    if fmt == FB_I8:
        w = word & 0xFF
        return [w, w, w, w]
    if fmt == FB_RGBA5551:
        return [(word >> 8) & 0xF8, (word >> 3) & 0xF8, (word << 2) & 0xF8, (word & 1) * 0xE0]
    return None                                  # 16-bit IA and 32-bit: nothing


# --- TMEM loads (tmem_update.comp, rdp_renderer.cpp load_tile) ----------------------------------
class Upload:
    __slots__ = ('width', 'height', 'min_line', 'max_line', 'vram_addr', 'vram_width', 'vram_size',
                 'vram_eff_width', 'tmem_offset', 'tmem_stride', 'tmem_size', 'tmem_fmt', 'mode', 'dxt')


def _rd16(rd, a):
    if a < 0 or a + 1 >= len(rd):
        return 0
    return (rd[a] << 8) | rd[a + 1]


def _rd32(rd, a):
    if a < 0 or a + 3 >= len(rd):
        return 0
    return (rd[a] << 24) | (rd[a + 1] << 16) | (rd[a + 2] << 8) | rd[a + 3]


def tmem_word_32(I, idx, upper, yuv, rd):
    """TMEM word idx (of one 2 kB half) after a 32-bit or YUV load, or None"""
    off = (I.tmem_offset & 0x7FF) >> 1
    stride = I.tmem_stride
    po = (idx - off) & 0x3FF
    xx = 0
    if I.mode == UPLOAD_BLOCK:
        wo = po >> 1
        if stride == 0:
            c1 = wo & ~1
            c2 = c1 + 1
            t1 = (c1 * I.dxt) >> 16
            t2 = (c2 * I.dxt) >> 16
            if t1 != t2:
                if c2 ^ (t2 & 1) == wo:
                    xx = (t2 & 1) << 1
                elif c1 ^ (t1 & 1) == wo:
                    xx = (t1 & 1) << 1
                else:
                    return None
            else:
                xx ^= (t1 & 1) << 1
        else:
            min_t = (wo & ~1) // I.max_line
            max_t = (wo | 1) // I.min_line
            maxc = (wo | 1) - stride * min_t
            minc = (wo & ~1) - stride * max_t
            min_t = max(min_t, (minc * I.dxt) >> 16)
            max_t = min(max_t, (maxc * I.dxt) >> 16)
            found = False
            t = max_t
            while t >= min_t:
                cf = (wo & ~1) - stride * t
                cs = (wo | 1) - stride * t
                ctf = (cf * I.dxt) >> 16
                cts = (cs * I.dxt) >> 16
                if ((cs + cts * stride) ^ (cts & 1)) == wo:
                    found = True
                    po = (cs << 1) + (po & 1)
                    break
                if ((cf + ctf * stride) ^ (ctf & 1)) == wo:
                    found = True
                    po = (cf << 1) + (po & 1)
                    break
                t -= 1
            if not found:
                return None
        ux, uy = po, 0
    elif stride == 0:
        ux, uy = po, I.height - 1
    else:
        uy = po // stride
        ux = po - uy * stride
        if uy >= I.height:
            ux += stride * (uy - I.height + 1)
            uy = I.height - 1
    last = ux ^ ((uy & 1) << 1)
    if last >= I.width and uy > 0:
        uy -= 1
        ux += stride
    ux ^= ((uy & 1) << 1) | xx
    if I.vram_size == 3 or yuv:
        it = 4 * (ux & ~1)
    elif I.vram_size == 2:
        if ux & 2:
            if uy > 0:
                uy -= 1
                ux += stride
                ux ^= 2
            else:
                return None
        it = 2 * (ux & ~1)
    else:
        i = 0
        while i < 4 and uy > 0 and (ux & 6) != 0:
            uy -= 1
            ux += stride
            ux ^= 2
            i += 1
        if ux & 6:
            return None
        it = ux & ~1
    if ux >= I.width:
        return None
    line = I.vram_addr + ((uy * I.vram_width) << (I.vram_size - 1))
    word = _rd32(rd, line + it + 4 * (ux & 1))
    if yuv:
        if upper:
            return (((word >> 16) & 0xFF) << 8) | (word & 0xFF)
        return (((word >> 24) & 0xFF) << 8) | ((word >> 8) & 0xFF)
    return (word >> 16) if not upper else (word & 0xFFFF)


def tmem_word_16(I, idx, rd):
    """TMEM word idx after a 4/8/16-bit load, or None"""
    off = (I.tmem_offset & 0xFFF) >> 1
    stride = I.tmem_stride
    po = (idx - off) & 0x7FF
    xx = 0
    if I.mode == UPLOAD_BLOCK:
        wo = po >> 2
        if stride == 0:
            xx = (((wo * I.dxt) >> 16) & 1) << 1
        else:
            min_t = wo // I.max_line
            max_t = wo // I.min_line
            maxc = wo - stride * min_t
            minc = wo - stride * max_t
            min_t = max(min_t, (minc * I.dxt) >> 16)
            max_t = min(max_t, (maxc * I.dxt) >> 16)
            found = False
            t = max_t
            while t >= min_t:
                cand = wo - stride * t
                ct = (cand * I.dxt) >> 16
                if cand + ct * stride == wo:
                    found = True
                    xx = (ct & 1) << 1
                    po = (cand << 2) + (po & 3)
                t -= 1
            if not found:
                return None
        ux, uy = po, 0
    elif stride == 0:
        ux, uy = po, I.height - 1
    else:
        uy = po // stride
        ux = po - uy * stride
        if uy >= I.height:
            ux += stride * (uy - I.height + 1)
            uy = I.height - 1
    if I.tmem_size != I.vram_size:
        if I.vram_size - I.tmem_size == 1:
            it = (ux & ~3) * 4
            if (ux & ~3) + 2 < (I.vram_eff_width >> (3 - I.vram_size)):
                it += 8
        elif I.tmem_size == 2 and I.vram_size == 1:
            if ux & 4:
                if (stride & 4) and uy > 0:
                    uy -= 1
                    ux += stride
                else:
                    return None
            it = ux & ~3
        else:
            return None
    else:
        it = (ux & ~3) * 2
    if ux >= I.width:
        return None
    line = I.vram_addr + ((uy * I.vram_width) << (I.vram_size - 1))
    ux ^= ((uy & 1) << 1) | xx
    return _rd16(rd, line + it + 2 * (ux & 3))


def tmem_word_lut(I, idx, rd):
    """TMEM word idx after LOAD_TLUT, or None"""
    off = (I.tmem_offset & 0xFFF) >> 1
    po = (idx - off) & 0x7FF
    d = I.vram_size - I.tmem_size
    if d == 2:
        sp = (po >> 2) << (I.vram_size - 2)
        if sp >= I.vram_eff_width:
            return None
    elif d == 1:
        if po & 4:
            return None
        sp = (po & ~7) >> (I.tmem_size + (2 if I.vram_size == 2 else 0))
        if sp >= I.vram_eff_width:
            return None
    elif d == 0:
        if po & 0xC:
            return None
        sp = (po & ~3) >> (I.tmem_size + (2 if I.vram_size == 2 else 0))
        if sp >= I.vram_eff_width:
            return None
    elif d == -1:
        if po & 0x1C:
            return None
        sp = (po >> I.tmem_size) & ~7
        if sp >= I.vram_eff_width:
            return None
    else:
        span = (po >> 2) * 2 * 2
        if span + 2 < I.vram_eff_width:
            span += 2
        if span >= I.vram_eff_width:
            return None
        sp = span
    a = I.vram_addr + (sp << (I.vram_size - 1))
    a += 2 * (a & 1) * (po & 3)
    return _rd16(rd, a)


def tmem_apply(tm, I, rd):
    """an upload into TMEM: every word finds the source that writes it last"""
    yuv = I.tmem_fmt == FMT_YUV
    for idx in range(2048):
        if I.mode == UPLOAD_TLUT:
            v = tmem_word_lut(I, idx, rd)
        elif I.tmem_size == 3 or yuv:
            v = tmem_word_32(I, idx & 0x3FF, idx >= 0x400, yuv, rd)
        else:
            v = tmem_word_16(I, idx, rd)
        if v is not None:
            tm[idx] = v


# --- the RDP -----------------------------------------------------------------------------------
class RDP:
    def __init__(self, bus):
        self.bus = bus
        # registers
        self.start = 0
        self.end = 0
        self.current = 0
        self.start_valid = 0
        self.source = 0             # 1: commands from DMEM (XBUS)
        self.freeze = 0
        self.flush = 0
        self.start_gclk = 0
        self.clock = 0
        self.pending = []           # 64-bit words of a command not yet whole
        # the ninth bits of RDRAM
        self.hidden = bytearray([3]) * (len(bus.rdram) >> 1)
        # state
        self.tmem = [0] * 2048
        self.tiles = [Tile() for _ in range(8)]
        self.om0 = 0                # SET_OTHER_MODES, high and low words
        self.om1 = 0
        self.comb = [(0,) * 8, (0,) * 8]    # per cycle: rgb a b c d, alpha a b c d
        self.scissor = (0, 0, 0, 0)         # xlo, ylo, xhi, yhi (10.2)
        self.scissor_field = 0
        self.scissor_odd = 0
        self.fill_color = 0
        self.fog_color = 0
        self.blend_color = 0
        self.prim_color = 0
        self.env_color = 0
        self.prim_min_level = 0
        self.prim_lod_frac = 0
        self.prim_depth = 0
        self.prim_dz = 0
        self.convert = [1, 1, 1, 1, 0, 0]
        self.key_center = [0, 0, 0]
        self.key_scale = [0, 0, 0]
        self.key_width = [0, 0, 0]
        self.timg = (0, 1, 0, 0)            # addr, width, fmt, size
        self.fb_addr = 0
        self.fb_width = 0
        self.fb_fmt = FB_RGBA5551
        self.z_addr = 0
        self.prims = 0                      # primitives drawn (seeds the noise)
        self.commands = 0
        self.pixels = 0
        self.trace = None                   # a list: per-pixel stage values are appended
        self.draw = True                    # False: keep all state, skip the pixels

    # --- registers ---------------------------------------------------------------------------
    def status(self):
        return (self.source | (self.freeze << 1) | (self.flush << 2) | (self.start_gclk << 3)
                | (1 << 7) | (self.start_valid << 10))

    def reg_read(self, i):
        i &= 7
        if i == 0: return self.start
        if i == 1: return self.end
        if i == 2: return self.current
        if i == 3: return self.status()
        if i == 4: return self.clock & 0xFFFFFF
        return 0

    def reg_write(self, i, v):
        i &= 7
        v &= M32
        if i == 0:
            if not self.start_valid:
                self.start = v & 0xFFFFF8
            self.start_valid = 1
        elif i == 1:
            self.end = v & 0xFFFFF8
            if self.start_valid:
                self.current = self.start
                self.start_valid = 0
            self.run()
        elif i == 3:
            if v & 1: self.source = 0
            if v & 2: self.source = 1
            if v & 4:
                self.freeze = 0
                self.run()
            if v & 8: self.freeze = 1
            if v & 16: self.flush = 0
            if v & 32: self.flush = 1
            if v & (1 << 9): self.clock = 0

    # --- the command walk ---------------------------------------------------------------------
    def fetch(self, a):
        if self.source:
            o = a & 0xFF8
            return int.from_bytes(self.bus.dmem[o:o + 8], 'big')
        a &= 0xFFFFF8
        rd = self.bus.rdram
        if a + 8 > len(rd):
            return 0
        return int.from_bytes(rd[a:a + 8], 'big')

    def run(self, m=None):
        """the commands from CURRENT to END; a command that END cuts waits for the rest"""
        if self.freeze:
            return
        self.start_gclk = 1
        while self.current < self.end:
            self.pending.append(self.fetch(self.current))
            self.current = (self.current + 8) & 0xFFFFFF
            op = (self.pending[0] >> 56) & 0x3F
            if len(self.pending) < cmd_len(op):
                continue
            words = []
            for d in self.pending:
                words.append(d >> 32)
                words.append(d & M32)
            self.pending = []
            self.clock += len(words)
            self.execute(op, words)

    def execute(self, op, w):
        self.commands += 1
        if 0x08 <= op <= 0x0F:
            copy = bool(self.raster_flags() & R_COPY)
            t = decode_edges(w, copy)
            a = Attr()
            i = 8
            if op & 4:
                decode_shade(a, w[i:i + 16])
                i += 16
            if op & 2:
                decode_texture(a, w[i:i + 16])
                i += 16
            if op & 1:
                decode_z(a, w[i:i + 4])
            self.draw_primitive(t, a)
        elif op == 0x24 or op == 0x25:
            self.texture_rectangle(w, op == 0x25)
        elif op == 0x29:                                        # SYNC_FULL
            self.bus.mi_intr |= 0x20
            self.start_gclk = 0
        elif op == 0x2A:                                        # SET_KEY_GB
            self.key_width[1] = (w[0] >> 12) & 0xFFF
            self.key_width[2] = w[0] & 0xFFF
            self.key_center[1] = (w[1] >> 24) & 0xFF
            self.key_scale[1] = (w[1] >> 16) & 0xFF
            self.key_center[2] = (w[1] >> 8) & 0xFF
            self.key_scale[2] = w[1] & 0xFF
        elif op == 0x2B:                                        # SET_KEY_R
            self.key_width[0] = (w[1] >> 16) & 0xFFF
            self.key_center[0] = (w[1] >> 8) & 0xFF
            self.key_scale[0] = w[1] & 0xFF
        elif op == 0x2C:                                        # SET_CONVERT
            m = (w[0] << 32) | w[1]
            k = [(m >> sh) & 0x1FF for sh in (45, 36, 27, 18, 9, 0)]
            self.convert = [2 * sext(k[0], 9) + 1, 2 * sext(k[1], 9) + 1, 2 * sext(k[2], 9) + 1,
                            2 * sext(k[3], 9) + 1, k[4], k[5]]
        elif op == 0x2D:                                        # SET_SCISSOR
            self.scissor = ((w[0] >> 12) & 0xFFF, w[0] & 0xFFF, (w[1] >> 12) & 0xFFF, w[1] & 0xFFF)
            self.scissor_field = (w[1] >> 25) & 1
            self.scissor_odd = (w[1] >> 24) & 1
        elif op == 0x2E:                                        # SET_PRIM_DEPTH
            self.prim_depth = ((w[1] >> 16) & 0x7FFF) << 16
            self.prim_dz = w[1] & 0xFFFF
        elif op == 0x2F:                                        # SET_OTHER_MODES
            self.om0, self.om1 = w[0], w[1]
        elif op == 0x30:
            self.load(w, UPLOAD_TLUT)
        elif op == 0x32:                                        # SET_TILE_SIZE
            t = self.tiles[(w[1] >> 24) & 7]
            t.slo, t.tlo = (w[0] >> 12) & 0xFFF, w[0] & 0xFFF
            t.shi, t.thi = (w[1] >> 12) & 0xFFF, w[1] & 0xFFF
        elif op == 0x33:
            self.load(w, UPLOAD_BLOCK)
        elif op == 0x34:
            self.load(w, UPLOAD_TILE)
        elif op == 0x35:                                        # SET_TILE
            t = self.tiles[(w[1] >> 24) & 7]
            t.offset = (w[0] & 511) << 3
            t.stride = ((w[0] >> 9) & 511) << 3
            t.size = (w[0] >> 19) & 3
            t.fmt = (w[0] >> 21) & 7
            t.palette = (w[1] >> 20) & 15
            t.shift_s = w[1] & 15
            t.mask_s = (w[1] >> 4) & 15
            t.shift_t = (w[1] >> 10) & 15
            t.mask_t = (w[1] >> 14) & 15
            f = 0
            if w[1] & (1 << 8): f |= TILE_MIRROR_S
            if w[1] & (1 << 9): f |= TILE_CLAMP_S
            if w[1] & (1 << 18): f |= TILE_MIRROR_T
            if w[1] & (1 << 19): f |= TILE_CLAMP_T
            if t.mask_s > 10: t.mask_s = 10
            elif t.mask_s == 0: f |= TILE_CLAMP_S
            if t.mask_t > 10: t.mask_t = 10
            elif t.mask_t == 0: f |= TILE_CLAMP_T
            t.flags = f
        elif op == 0x36:
            self.fill_rectangle(w)
        elif op == 0x37:
            self.fill_color = w[1]
        elif op == 0x38:
            self.fog_color = w[1]
        elif op == 0x39:
            self.blend_color = w[1]
        elif op == 0x3A:
            self.prim_min_level = (w[0] >> 8) & 31
            self.prim_lod_frac = w[0] & 0xFF
            self.prim_color = w[1]
        elif op == 0x3B:
            self.env_color = w[1]
        elif op == 0x3C:                                        # SET_COMBINE
            a, b = w[0], w[1]
            self.comb = [((a >> 20) & 15, (b >> 28) & 15, (a >> 15) & 31, (b >> 15) & 7,
                          (a >> 12) & 7, (b >> 12) & 7, (a >> 9) & 7, (b >> 9) & 7),
                         ((a >> 5) & 15, (b >> 24) & 15, a & 31, (b >> 6) & 7,
                          (b >> 21) & 7, (b >> 3) & 7, (b >> 18) & 7, b & 7)]
        elif op == 0x3D:                                        # SET_TEXTURE_IMAGE
            self.timg = (w[1] & 0xFFFFFF, (w[0] & 0x3FF) + 1, (w[0] >> 21) & 7, (w[0] >> 19) & 3)
        elif op == 0x3E:                                        # SET_MASK_IMAGE
            self.z_addr = w[1] & 0xFFFFFF
        elif op == 0x3F:                                        # SET_COLOR_IMAGE
            fmt = (w[0] >> 21) & 7
            size = (w[0] >> 19) & 3
            self.fb_width = (w[0] & 1023) + 1
            self.fb_addr = w[1] & 0xFFFFFF
            self.fb_fmt = (FB_I4, FB_I8, FB_IA88 if fmt else FB_RGBA5551, FB_RGBA8888)[size]
        # 0x00 no-op, 0x26-0x28 syncs, and the invalid codes do nothing

    # --- modes --------------------------------------------------------------------------------
    def raster_flags(self):
        """the rasteriser's flags, from the other modes and the scissor (op_set_other_modes)"""
        w0, w1 = self.om0, self.om1
        f = 0
        for bit, flag in ((19, R_PERSPECTIVE), (18, R_DETAIL_LOD), (17, R_SHARPEN_LOD), (16, R_TEX_LOD),
                          (15, R_TLUT), (14, R_TLUT_TYPE), (13, R_SAMPLE_QUAD), (12, R_MID_TEXEL),
                          (11, R_BILERP0), (10, R_BILERP1), (9, R_CONVERT_ONE)):
            if w0 >> bit & 1:
                f |= flag
        for bit, flag in ((13, R_ALPHA_CVG_SELECT), (12, R_CVG_TIMES_ALPHA), (3, R_AA),
                          (1, R_ALPHA_TEST_DITHER), (0, R_ALPHA_TEST)):
            if w1 >> bit & 1:
                f |= flag
        cyc = (w0 >> 20) & 3
        if cyc == 1: f |= R_MULTI_CYCLE
        elif cyc == 2: f |= R_COPY
        elif cyc == 3: f |= R_FILL
        if self.scissor_field: f |= R_INTERLACE_FIELD
        if self.scissor_odd: f |= R_INTERLACE_KEEP_ODD
        return f

    def depth_blend_flags(self):
        w0, w1 = self.om0, self.om1
        f = 0
        for bit, flag in ((14, DB_FORCE_BLEND), (7, DB_COLOR_ON_CVG), (6, DB_IMAGE_READ),
                          (5, DB_DEPTH_UPDATE), (4, DB_DEPTH_TEST), (3, DB_AA)):
            if w1 >> bit & 1:
                f |= flag
        if ((w0 >> 4) & 0xF) >> 2 != 3:
            f |= DB_DITHER
        if ((w0 >> 20) & 3) == 1:
            f |= DB_MULTI_CYCLE
        return f

    @staticmethod
    def _accesses(c, t):
        """does a cycle's combiner read texel t (1 or 2)?"""
        return (c[0] == t or c[1] == t or c[2] == t or c[3] == t or c[2] == t + 7
                or c[4] == t or c[5] == t or c[6] == t or c[7] == t)

    def static_flags(self, tile):
        """deduce_static_texture_state + deduce_noise_state + normalize_static_state"""
        f = self.raster_flags()
        dither = (self.om0 >> 4) & 0xF
        c0, c1 = self.comb
        if not f & (R_COPY | R_FILL):
            multi = f & R_MULTI_CYCLE
            uses_t0 = (self._accesses(c0, 1) or self._accesses(c1, 2)) if multi else self._accesses(c1, 1)
            uses_t1 = (self._accesses(c0, 2) or self._accesses(c1, 1)) if multi else False
            uses_pipe = False if multi else self._accesses(c1, 2)
            # LOD_FRAC in cycle 1 mode: parallel-RDP leaves it undefined there; krom's
            # screenshots show hardware computing it as in cycle 2 mode, so it is
            uses_lodf = ((c0[2] == 13 or c0[6] == 0) or (c1[2] == 13 or c1[6] == 0)) if multi                 else (c1[2] == 13 or c1[6] == 0)
            if uses_t1 and f & R_CONVERT_ONE:
                uses_t0 = True
            if uses_t0: f |= R_USES_TEXEL0
            if uses_t1: f |= R_USES_TEXEL1
            if uses_pipe: f |= R_USES_PIPELINED_TEXEL1
            if uses_lodf or f & R_TEX_LOD: f |= R_USES_LOD
        # noise
        if (dither & 3) == 2 or ((dither >> 2) & 3) == 2:
            f |= R_NEED_NOISE
        elif not f & (R_COPY | R_FILL):
            if (f & R_MULTI_CYCLE) and c0[0] == 7:
                f |= R_NEED_NOISE
            if c1[0] == 7:
                f |= R_NEED_NOISE
            if (f & R_MULTI_CYCLE) and c0[0] == 7 and c1[0] == 7:
                f |= R_NEED_NOISE_DUAL
            if (f & (R_ALPHA_TEST | R_ALPHA_TEST_DITHER)) == (R_ALPHA_TEST | R_ALPHA_TEST_DITHER):
                f |= R_NEED_NOISE
        # normalize
        if f & R_FILL:
            return R_FILL | (f & R_NEED_NOISE)
        if f & R_COPY:
            return f & (R_COPY | R_TLUT | R_TLUT_TYPE | R_USES_TEXEL0 | R_TEX_LOD | R_DETAIL_LOD
                        | R_PERSPECTIVE | R_ALPHA_TEST | R_NEED_NOISE)
        if not f & (R_MULTI_CYCLE | R_USES_PIPELINED_TEXEL1):
            f &= ~(R_BILERP1 | R_CONVERT_ONE)
        return f

    # --- TMEM loads ---------------------------------------------------------------------------
    def load(self, w, mode):
        tile = (w[1] >> 24) & 7
        slo, tlo = (w[0] >> 12) & 0xFFF, w[0] & 0xFFF
        shi, thi = (w[1] >> 12) & 0xFFF, w[1] & 0xFFF
        addr, width, fmt, size = self.timg
        meta = self.tiles[tile]
        if mode != UPLOAD_BLOCK:
            if (thi >> 2) < (tlo >> 2):
                return
            if not ((((shi >> 2) - (slo >> 2)) + 1) & 0xFFF):
                return
        else:
            pc = ((shi - slo) + 1) & 0xFFF
            if not pc or pc > 2048:
                return
        if mode == UPLOAD_TILE:
            pixels = (((shi >> 2) - (slo >> 2)) + 1) & 0xFFF
            qw = ((pixels << meta.size) + 15) >> 4
            if meta.size > size:
                qw <<= meta.size - size
            elif meta.size < size:
                qw >>= size - meta.size
            per_line = max(qw * 8, meta.stride)
            max_bytes = 0x800 if meta.fmt == FMT_YUV else 0x1000
            lines = ((thi >> 2) - (tlo >> 2)) + 1
            if per_line * lines > max_bytes:
                # more than TMEM in one go: in pieces, as it would wrap
                step = (max_bytes // per_line) & ~1
                if step == 0:
                    return
                for line in range(0, lines, step):
                    n = min(lines - line, step)
                    t_lo = tlo + (line << 2)
                    self.load_iteration(tile, mode, slo, shi, t_lo, t_lo + ((n - 1) << 2), line * meta.stride)
                meta.slo, meta.shi, meta.tlo, meta.thi = slo, shi, tlo, thi
                return
        self.load_iteration(tile, mode, slo, shi, tlo, thi, 0)

    def load_iteration(self, tile, mode, slo, shi, tlo, thi, tmem_offset):
        addr, tex_width, fmt, size = self.timg
        meta = self.tiles[tile]
        meta.slo, meta.shi, meta.tlo, meta.thi = slo, shi, tlo, thi
        if meta.fmt == FMT_YUV and (meta.size != 2 or size != 2):
            return
        if size == 0:                       # a 4-bit texture image crashes the RDP
            return
        if meta.size == 3 and meta.fmt != FMT_RGBA:
            return
        if mode == UPLOAD_TLUT and meta.size == 3:
            return
        if mode != UPLOAD_TLUT:
            if (size == 3 and meta.size == 1) or (size == 2 and meta.size == 0) or (size == 3 and meta.size == 0):
                return
        I = Upload()
        I.tmem_stride = meta.stride >> 1
        I.min_line = I.max_line = 1
        I.dxt = 0
        if mode == UPLOAD_BLOCK:
            ux, uy = slo, tlo
            pixel_count = (shi - slo + 1) & 0xFFF
            dt = thi
            max_iter = (pixel_count - 1) >> (4 - size)
            max_t = (max_iter * dt) >> 11
            if max_t != 0:
                max_n = ((1 << 11) + dt - 1) // dt
                min_n = (1 << 11) // dt
                uneven = max_n != min_n
                if uneven:
                    overflow_amt = (dt * max_n - (1 << 11)) * max_t
                    if overflow_amt < dt:
                        min_n = max_n
                        uneven = False
                I.dxt = dt << 5
                if meta.size == 3 or meta.fmt == FMT_YUV:
                    I.tmem_stride <<= 1
                    if uneven and meta.size != size:
                        return
                if meta.size > size:
                    sh = meta.size - size
                    max_n <<= sh
                    min_n <<= sh
                    I.dxt >>= sh
                elif size > meta.size:
                    return
                I.max_line = max_n + (I.tmem_stride >> 2)
                I.min_line = min_n + (I.tmem_stride >> 2)
                I.width = pixel_count
                I.height = 1
                I.tmem_stride >>= 2
            else:
                I.width = pixel_count
                I.height = 1
                I.tmem_stride = 0
                mode = UPLOAD_TILE
        else:
            ux, uy = slo >> 2, tlo >> 2
            I.width = (((shi >> 2) - (slo >> 2)) + 1) & 0xFFF
            I.height = ((thi >> 2) - (tlo >> 2)) + 1
        if not I.width:
            return
        if size == 1:
            I.vram_eff_width = (I.width + 7) & ~7
        elif size == 2:
            I.vram_eff_width = I.width if mode == UPLOAD_TLUT else (I.width + 3) & ~3
        else:
            I.vram_eff_width = (I.width + 1) & ~1
        if meta.size == 0:
            I.width = ((I.width + 15) & ~15) >> 2
        elif meta.size == 1:
            I.width = ((I.width + 7) & ~7) >> 1
        elif meta.size == 2:
            I.width = (I.width + 3) & ~3
            if meta.fmt == FMT_YUV:
                I.width >>= 1
        else:
            I.width = (I.width + 1) & ~1
        if I.height > 1 and mode == UPLOAD_TLUT:
            return
        I.vram_addr = addr + ((tex_width * uy + ux) << (size - 1))
        I.vram_width = I.vram_eff_width if mode == UPLOAD_BLOCK else tex_width
        I.vram_size = size
        I.tmem_offset = (meta.offset + tmem_offset) & 0xFFF
        I.tmem_size = meta.size
        I.tmem_fmt = meta.fmt
        I.mode = mode
        tmem_apply(self.tmem, I, self.bus.rdram)

    # --- primitives ---------------------------------------------------------------------------
    def fill_rectangle(self, w):
        xl, yl = (w[0] >> 12) & 0xFFF, w[0] & 0xFFF
        xh, yh = (w[1] >> 12) & 0xFFF, w[1] & 0xFFF
        if self.raster_flags() & (R_COPY | R_FILL):
            yl |= 3
        t = Tri()
        t.xh = xh << 13
        t.xl = t.xm = xl << 13
        t.ym = t.yl = yl
        t.yh = yh
        t.flags = TRI_FLIP
        self.draw_primitive(t, Attr())

    def texture_rectangle(self, w, flipped):
        xl, yl = (w[0] >> 12) & 0xFFF, w[0] & 0xFFF
        xh, yh = (w[1] >> 12) & 0xFFF, w[1] & 0xFFF
        tile = (w[1] >> 24) & 7
        s, t_ = (w[2] >> 16) & 0xFFFF, w[2] & 0xFFFF
        dsdx, dtdy = sext(w[3] >> 16, 16), sext(w[3], 16)
        f = self.raster_flags()
        if f & (R_COPY | R_FILL):
            yl |= 3
        t = Tri()
        t.xh = xh << 13
        t.xl = t.xm = xl << 13
        t.ym = t.yl = yl
        t.yh = yh
        t.flags = TRI_FLIP | (TRI_SKIP_XFRAC if f & R_COPY else 0)
        t.tile = tile
        a = Attr()
        a.stzw[0] = s32(s << 16)
        a.stzw[1] = s32(t_ << 16)
        if not flipped:
            a.dstzw_dx[0] = s32(dsdx << 11)
            a.dstzw_de[1] = s32(dtdy << 11)
            a.dstzw_dy[1] = s32(dtdy << 11)
        else:
            a.dstzw_dx[1] = s32(dtdy << 11)
            a.dstzw_de[0] = s32(dsdx << 11)
            a.dstzw_dy[0] = s32(dsdx << 11)
        self.draw_primitive(t, a)

    def draw_primitive(self, t, a):
        """draw_shaded_primitive: per-primitive setup, then every scanline and pixel"""
        rf = self.raster_flags()
        # fixup_triangle_setup
        if t.ym < (t.yh & ~3):
            t.ym = 0x7FFF
        if rf & R_INTERLACE_FIELD:
            t.flags |= TRI_INTERLACE_FIELD
            if rf & R_INTERLACE_KEEP_ODD:
                t.flags |= TRI_INTERLACE_KEEP_ODD
        if rf & (R_COPY | R_FILL):
            t.flags |= TRI_FILL_COPY_RASTER
        use_prim_depth = (self.om1 >> 2) & 1
        dz, dz_c = primitive_dz(a, use_prim_depth, self.prim_dz)
        if use_prim_depth:
            a = a.copy()
            a.stzw[2] = self.prim_depth
            a.dstzw_dx[2] = a.dstzw_de[2] = a.dstzw_dy[2] = 0
        self.prims += 1
        if not self.draw or not self.fb_width:
            return
        sc = self.scissor
        ylo = max(t.yh, sc[1]) >> 2
        yhi = min(t.yl - 1, sc[3] - 1) >> 2
        if yhi < ylo:
            return
        P = Primitive(self, t, a, dz, dz_c)
        P.run(ylo, yhi)
        if hasattr(self.bus, 'rdram_writes'):
            self.bus.rdram_writes += 1          # (n64model.run: a machine that draws is not idle)


class Primitive:
    """one primitive's state, as the pipeline sees it, and its pixels"""

    def __init__(self, rdp, t, a, dz, dz_c):
        self.rdp = rdp
        self.t = t
        self.a = a
        self.dz = dz
        self.dz_c = dz_c
        self.flags = rdp.static_flags(t.tile & 7)
        self.dbf = rdp.depth_blend_flags()
        self.dither = (rdp.om0 >> 4) & 0xF
        w1 = rdp.om1
        self.blend_modes = (((w1 >> 30) & 3, (w1 >> 26) & 3, (w1 >> 22) & 3, (w1 >> 18) & 3),
                            ((w1 >> 28) & 3, (w1 >> 24) & 3, (w1 >> 20) & 3, (w1 >> 16) & 3))
        self.cov_mode = (w1 >> 8) & 3
        self.z_mode = (w1 >> 10) & 3
        self.comb = rdp.comb
        self.k = [combiner_constants(c, rdp.prim_color, rdp.env_color, rdp.key_center, rdp.key_scale,
                                     rdp.convert, rdp.prim_lod_frac) for c in rdp.comb]
        self.fog = [(rdp.fog_color >> s) & 0xFF for s in (24, 16, 8, 0)]
        self.blend_col = [(rdp.blend_color >> s) & 0xFF for s in (24, 16, 8, 0)]
        self.factors = rdp.convert[:4]
        self.min_lod = rdp.prim_min_level
        self.tiles = rdp.tiles
        self.scissor = rdp.scissor
        self.fmt = rdp.fb_fmt
        self.width = rdp.fb_width
        shift = {FB_I4: 0, FB_I8: 0, FB_RGBA5551: 1, FB_IA88: 1, FB_RGBA8888: 2}[self.fmt]
        self.fb_index = rdp.fb_addr >> shift
        self.z_index = rdp.z_addr >> 1
        self.fb_size, self.dx_mask, self.dx_shift = {FB_I4: (0, 0, 0), FB_I8: (1, ~7, 3),
                                                    FB_RGBA5551: (2, ~3, 2), FB_IA88: (2, ~3, 2),
                                                    FB_RGBA8888: (4, ~1, 1)}[self.fmt]
        self.prim_index = rdp.prims

    def run(self, ylo, yhi):
        rdp = self.rdp
        t, a = self.t, self.a
        spans = [span_setup(t, a, self.scissor, y) for y in range(ylo, yhi + 2)]
        f = self.flags
        rd, hidden = rdp.bus.rdram, rdp.hidden
        width = self.width
        for y in range(ylo, yhi + 1):
            sp = spans[y - ylo]
            if not sp.valid:
                continue
            nxt = spans[y - ylo + 1]
            x0 = sp.start_x
            x1 = min(sp.end_x, width - 1)
            row = width * y
            if f & R_FILL:
                if x1 >= x0 and self.fill_span(row + self.fb_index + x0, x1 - x0 + 1, rd, hidden):
                    rdp.pixels += x1 - x0 + 1
                    continue
                for x in range(x0, x1 + 1):
                    idx = self.fb_index + row + x
                    c = fill_pixel_color(self.fmt, rdp.fill_color, idx)
                    if c is not None:
                        store_color(self.fmt, rd, hidden, idx, c)
                    rdp.pixels += 1
                continue
            if f & R_COPY:
                for x in range(x0, x1 + 1):
                    self.copy_pixel(x, y, sp, rd, hidden)
                continue
            for x in range(x0, x1 + 1):
                out = self.shade_pixel(x, y, sp, nxt)
                if out is not None:
                    self.depth_blend(x, y, out, rd, hidden)

    def fill_span(self, i0, n, rd, hidden):
        """FILL mode on n pixels from framebuffer index i0 at once: the same bytes
        fill_pixel_color and store_color give pixel by pixel (16 and 32-bit;
        False for the formats left to the pixel loop, and at the end of RDRAM)"""
        fill = self.rdp.fill_color
        if self.fmt == FB_RGBA5551:
            if 2 * (i0 + n) > len(rd):
                return False
            pat = fill.to_bytes(4, 'big')
            if i0 & 1:
                pat = pat[2:] + pat[:2]
            rd[2 * i0:2 * (i0 + n)] = (pat * ((n >> 1) + 1))[:2 * n]
            h = bytes((3 * ((fill >> 16) & 1), 3 * (fill & 1)))
            if i0 & 1:
                h = h[::-1]
            hidden[i0:i0 + n] = (h * ((n >> 1) + 1))[:n]
            return True
        if self.fmt == FB_RGBA8888:
            if 4 * (i0 + n) > len(rd):
                return False
            rd[4 * i0:4 * (i0 + n)] = fill.to_bytes(4, 'big') * n
            hidden[2 * i0:2 * (i0 + n)] = bytes((3 * ((fill >> 16) & 1), 3 * (fill & 1))) * n
            return True
        return False

    # --- copy -------------------------------------------------------------------------------------
    def copy_pixel(self, x, y, sp, rd, hidden):
        f = self.flags
        tile = self.tiles[self.t.tile & 7]
        s, t, s_off = interpolate_st_copy(sp, self.a.dstzw_dx, x, f & R_PERSPECTIVE, self.t.flags & TRI_FLIP,
                                          self.dx_mask, self.dx_shift)
        word = sample_texture_copy(self.rdp.tmem, tile, s, t, s_off, f & R_TLUT, self.fb_size)
        if f & R_ALPHA_TEST and self.fb_size == 2 and not word & 1:
            return
        c = copy_pixel_color(self.fmt, word)
        if c is not None:
            store_color(self.fmt, rd, hidden, self.fb_index + self.width * y + x, c)
        self.rdp.pixels += 1

    # --- the pixel (shading.h shade_pixel) -----------------------------------------------------
    def shade_pixel(self, x, y, sp, nxt):
        f = self.flags
        cov = compute_coverage(sp.xleft, sp.xright, x)
        if not cov:
            return None
        cc = popcount(cov)
        aa = f & R_AA
        if not aa and not cov & 1:
            return None
        a = self.a
        flip = self.t.flags & TRI_FLIP
        dx = x - sp.base_x
        direction = 1 if flip else -1
        shade = interpolate_rgba(sp.rgba, a.drgba_dx, a.drgba_dy, dx, cov)
        persp = f & R_PERSPECTIVE
        uses_lod = f & R_USES_LOD
        st, st_dx, st_dy, z, povf = interpolate_stz(sp.stzw, a.dstzw_dx, a.dstzw_dy, dx, cov, persp,
                                                    uses_lod, direction)
        noise = 0
        if f & R_NEED_NOISE:
            noise = reseed_noise(x, y, self.prim_index)
        tile0 = self.t.tile & 7
        tile1 = (tile0 + 1) & 7
        lod_frac = 0
        if uses_lod:
            tile0, tile1, lod_frac = compute_lod(tile0, tile1, self.t.tile >> 3, self.min_lod, st, st_dx, st_dy,
                                                 povf, f & R_TEX_LOD, f & R_SHARPEN_LOD, f & R_DETAIL_LOD)
        tm = self.rdp.tmem
        tlut, tlut_type = f & R_TLUT, f & R_TLUT_TYPE
        quad, mid = f & R_SAMPLE_QUAD, f & R_MID_TEXEL
        texel0 = texel1 = _Z4
        if f & R_USES_TEXEL0:
            texel0 = sample_texture(tm, self.tiles[tile0], st, tlut, tlut_type, quad, mid, False,
                                    f & R_BILERP0, self.factors, _Z4)
        uses_t1 = f & R_USES_TEXEL1
        if f & R_USES_PIPELINED_TEXEL1:
            # cycle 1 mode's TEXEL1 is the next pixel's TEXEL0 (or the next line's first)
            end_span = x == (sp.end_x if flip else sp.start_x)
            if end_span and sp.lodlength >= 8 and nxt.valid:
                ss, tt = nxt.stzw[0] >> 16, nxt.stzw[1] >> 16
                ww = nxt.stzw[3] >> 16
                st = (perspective_divide if persp else no_perspective_divide)(ss, tt, ww)[:2]
            else:
                st = interpolate_st_single(sp.stzw, a.dstzw_dx, dx + direction, persp)
            tile1 = tile0
            uses_t1 = True
        if uses_t1:
            if f & R_CONVERT_ONE and not f & R_BILERP1:
                texel1 = tuple(sext(v, 16) for v in texture_convert_factors(texel0, self.factors))
            else:
                texel1 = sample_texture(tm, self.tiles[tile1], st, tlut, tlut_type, quad, mid,
                                        f & R_CONVERT_ONE, f & R_BILERP1, self.factors, texel0)
        rgb_dith, alpha_dith = dither_coefficients(x, y >> (1 if f & R_INTERLACE_FIELD else 0),
                                                   self.dither >> 2, self.dither & 3, noise)
        I = CombinerInputs()
        I.shade = shade
        I.combined = _Z4
        I.texel0 = texel0
        I.texel1 = texel1
        I.lod_frac = lod_frac
        I.noise = ((noise & 7) << 6) | 0x20
        cvg_ta, acs = f & R_CVG_TIMES_ALPHA, f & R_ALPHA_CVG_SELECT
        alpha_test = f & R_ALPHA_TEST
        if f & R_MULTI_CYCLE:
            I.combined, alpha_ref = combiner_cycle0(self.comb[0], self.k[0], I, alpha_dith, cc, cvg_ta, acs,
                                                    alpha_test)
            I.texel0, I.texel1 = texel1, texel0
            if f & R_NEED_NOISE_DUAL:
                n2 = reseed_noise(x + 1023, y + 7, self.prim_index + 11)
                I.noise = ((n2 & 7) << 6) | 0x20
            combined, cc = combiner_cycle1(self.comb[1], self.k[1], I, alpha_dith, cc, cvg_ta, acs)
        else:
            combined, cc = combiner_cycle1(self.comb[1], self.k[1], I, alpha_dith, cc, cvg_ta, acs)
            alpha_ref = combined[3]
        if aa and cc == 0:
            return None
        if alpha_test:
            threshold = (noise & 0xFF) if f & R_ALPHA_TEST_DITHER else self.blend_col[3]
            if alpha_ref < threshold:
                return None
        tr = self.rdp.trace
        if tr is not None:
            tr.append(dict(x=x, y=y, cov=cov, shade=list(shade), st=st, z=z, texel0=texel0, texel1=texel1,
                           lod_frac=lod_frac, combined=list(combined), cc=cc))
        return combined, z, rgb_dith, cc, min(shade[3] + alpha_dith, 0xFF)

    # --- the memory side (memory_interfacing.h depth_blend) ----------------------------------------
    def depth_blend(self, x, y, out, rd, hidden):
        combined, z, dith, cc, shade_alpha = out
        dbf = self.dbf
        idx = self.fb_index + self.width * y + x
        zidx = self.z_index + self.width * y + x
        cur = load_color(self.fmt, rd, hidden, idx)
        mem_depth, mem_dz = load_depth(rd, hidden, zidx)
        memory = decode_memory_color(self.fmt, cur, dbf & DB_IMAGE_READ)
        mem_cov = memory[3] >> 5
        force_blend = dbf & DB_FORCE_BLEND
        aa = dbf & DB_AA
        ok, cc, blend_en, wrap, shift = depth_test(z, self.dz, self.dz_c, mem_depth, mem_dz, cc, mem_cov,
                                                    dbf & DB_DEPTH_TEST, self.z_mode, force_blend, aa)
        self.rdp.pixels += 1
        if not ok or (aa and cc == 0):
            return
        pixel = combined
        modes = self.blend_modes[0]
        con = dbf & DB_COLOR_ON_CVG
        if dbf & DB_MULTI_CYCLE:
            rgb = blender(pixel, memory, self.fog, self.blend_col, shade_alpha, modes, force_blend, blend_en,
                          con, wrap, shift, False)
            pixel = rgb + [combined[3]]
            modes = self.blend_modes[1]
        rgb = blender(pixel, memory, self.fog, self.blend_col, shade_alpha, modes, force_blend, blend_en,
                      con, wrap, shift, True)
        if dbf & DB_DITHER:
            rgb = rgb_dither(rgb, dith)
        new_cov = blend_coverage(cc, mem_cov, blend_en, self.cov_mode)
        # (4-bit: write_color keeps the alpha it loaded, which the store puts in the ninth bits)
        store_color(self.fmt, rd, hidden, idx, rgb + [cur[3] if self.fmt == FB_I4 else new_cov << 5])
        if dbf & DB_DEPTH_UPDATE:
            store_depth(rd, hidden, zidx, z_compress(z), self.dz_c)


# the blender's divider (luts.hpp blender_lut): [(sum << 11) | (blended >> 2)]
BLENDER_LUT = zlib.decompress(base64.b64decode(''.join((
    'eNrt2XWYVVUbBXC7W7BbMUBsDGwxQUwwBrExRrGxWywUA8EYxEAxBjAQDGwQA8RAMAYbMcBWbOV717vede455w4z4Mgz+s3l'
    'rxn3nHv23medtX/PdZZZSv9K/0r/Sv9K/0r/Sv8a3L9ZZ5t9jjnnmnueeeebf4EFF1p4kUUXW7xR4yWWXGrpZZZdbvkVVlxp'
    '5VVWXa3J6musuVbTZms3X2fd9dbfYMONWmy8yaabtdx8iy232nqbbbdrtf0OO+608y6t2+zadrfd99hzr73btd9n3/32L+tw'
    'QMcDDzr4kEMPO7zTEUcedXT5Mcd2Pu74E0486eRTupx62ulnnHnW2eece975F1x4UdeLL7n0ssu7XXFl96uuvubaHtf17HX9'
    'DTfeVNH75j633Hrb7X3vuLPfXXffc29l/wED77v/gQcHPTR4yMOPPPrY0MefePKpp595dtjw50Y8/8KLL40c9fLoV1597fUx'
    'b4wd9+Zbb79TNf7d997/4MOPPp7wycRPP/v8i0mTv/zq62++/e77H36c8tPPv/z62+9//PnX1NrWj/HsflW/fzWNT8/1uv/f'
    'vf6fuv+MPv//9/WXnv/Mff9Lz7/0/peefz2uf5ZZZ51tttlnn2OOOeeca665555nnnnnnW+++edfYIEFF1xooYUXXmSRRRdd'
    'bLHFF2/UqHHjJZZYcsmlllp66WWWWXbZ5ZZbfvkVVlhxxZVWWnnlVVZZddXVVmvSZPXV11hjzTXXWqtp02bN1l67efN11ll3'
    '3fXWW3/9DTbYcMONNmrRYuONN9lk000326xly80332KLLbfcaqutt95mm2233W67Vq22336HHXbccaeddt55l11at27TZtdd'
    '27bdbbfdd99jjz333Guvvfdu1659+3322Xff/fbbf/+ysg4dDjigY8cDDzzooIMPPuSQQw897LDDD+/U6YgjjjzyqKOOPrq8'
    '/Jhjjj22c+fjjjv++BNOOPHEk046+eRTTunS5dRTTzvt9NPPOOPMM8866+yzzznn3HPPO+/88y+44MILL7qoa9eLL77kkksv'
    'veyyyy/v1u2KK668snv3q666+uprrrn22h49rruuZ89eva6//oYbbrzxppsqKnr3vvnmPn1uueXWW2+77fbb+/a944477+zX'
    '76677r77nnvuvbeysn//AQMGDrzvvvvvf+CBBx8cNOihhwYPHjLk4YcfeeTRRx97bOjQxx9/4oknn3zqqaeffuaZZ58dNmz4'
    '8OeeGzHi+edfeOHFF196aeTIUaNefnn06FdeefXV1157/fUxY954Y+zYcePefPOtt95++513qqrGj3/33ffee//9Dz748MOP'
    'Pvr44wkTPvlk4sRPP/3ss88//+KLSZMmT/7yy6+++vrrb7759tvvvvv++x9++PHHKVN++unnn3/55ddff/vt99//+OPPP//6'
    'a+rU+n7+td1f4+m81pTfaY1P7/Uzuv6Zff9/+/r/6+9/6fmX3v+G/fztP9hf2J/YZ9iH2KfYx9g8bCI2E5uKzcUmY7Ox6dh+'
    '2IbYjtiW2J7Yptiu2LbYvtjG2M7Y1tje2ObY7tj2WD4sIJYQi4hlxEJiKbGYWE4sKJYUi4plxcJiabG4WF4sMJYYi4xlxkJj'
    'qbHYWG4sOJYci45lx8Jj6bH4WH9YgViDWIVYh1iJWItYjViPWJFYk1iVWJdYmVibWJ1Yn1ihWKNYpVinWKlYq1itWK9YsViz'
    'WLVYt1i5WLtYvVi/WMFYw1jFWMdYyVjLWM1Yz1jRWNNY1VjXWNlY21jdWN9Y4VjjWOVY51jpWOtY7VjvWPFY81j1WPdY+Vj7'
    'WP2YPwwgJhAjiBnEEGIKMYaYQwwiJhGjiFnEMGIaMY6YRwwkJhIjiZnEUGIqMZaYSwwmJhOjidnEcGI6MZ6YTwwoJhQjihnF'
    'kGJKMaaYUwwqJhWjilnFsGJaMa6YVwwsJhYji5nF0GJqMbaYWwwuJheji9nF8GJ6Mb6YXwwwJhgjjBnGEGOKMcaYYwwyJhmj'
    'jFnGMGOaMc6YZww0JhojjZnGUGOqMdaYaww2JhujjdnGcGO6Md6Ybww4JhwjjhnHkGPKMeaYcww6Jh2jjlnHsGPaMe6Ydww8'
    'Jh4jj5nH0GPqMfaYeww+Jh+jj9nH8GP6Mf5Mndn5T39+4X37++/f9F5f3fg/cf/S+//Pvv+l51+35/9vX/9/4P3Hf8Bf4E/w'
    'GfgQfAo+BvPARDATTAVzwWQwG0wH+4ENwY5gS7An2BTsCrYF+4KNwc5ga7A32BzsDrYH+UBAkBBEBBlBSJASxAQ5QVCQFEQF'
    'WUFYkBbEBXlBYJAYRAaZQWiQGsQGuUFwkBxEB9lBeJAexAf9gQJBg6BC0CEoEbQIagQ9giJBk6BK0CUoE7QJ6gR9gkJBo6BS'
    '0CkoFbQKagW9gmJBs6Ba0C0oF7QL6gX9goJBw6Bi0DEoGbQMagY9g6JB06Bq0DUoG7QN6gZ9g8JB46By0DkoHbQOage9g+JB'
    '86B60D0oH7QP6gf+AEAgEBAEBgFCoBAwBA4BRCARUAQWAUagEXAEHgFIIBKQBCYBSqASsAQuAUwgE9AENgFOoBPwBD4BUCAU'
    'EAVGAVKgFDAFTgFUIBVQBVYBVqAVcAVeAVggFpAFZgFaoBawBW4BXCAX0AV2AV6gF/AFfgFgIBgQBoYBYqAYMAaOAWQgGVAG'
    'lgFmoBlwBp4BaCAakAamAWqgGrAGrgFsIBvQBrYBbqAb8Aa+AXAgHBAHxgFyoBwwB84BdCAdUAfWAXagHXAH3gF4IB6QB+YB'
    'eqAesAfuAXwgH9AH9gF+oB/wZ2rp/W/Y739Df/71vf663r+26/Pj+r0IAP4X/if+Gf4h/in+MT4Pn4jPxKfic/HJ+Gx8Or4f'
    'viG+I74lvie+Kb4rvi2+L74xvjO+Nb43vjm+O749ng8PiCfEI+IZ8ZB4SjwmnhMPiifFo+JZ8bB4WjwunhcPjCfGI+OZ8dB4'
    'ajw2nhsPjifHo+PZ8fB4ejw+3h9eIN4gXiHeIV4i3iJeI94jXiTeJF4l3iVeJt4mXifeJ14o3iheKd4pXireKl4r3iteLN4s'
    'Xi3eLV4u3i5eL94vXjDeMF4x3jFeMt4yXjPeM1403jReNd41XjbeNl433jdeON44XjneOV463jpeO947XjzePF493j1ePt4+'
    'Xj/uDweIC8QJ4gZxhLhCnCHuEIeIS8Qp4hZxjLhGnCPuEQeJi8RJ4iZxlLhKnCXuEoeJy8Rp4jZxnLhOnCfuEweKC8WJ4kZx'
    'pLhSnCnuFIeKS8Wp4lZxrLhWnCvuFQeLi8XJ4mZxtLhanC3uFoeLy8Xp4nZxvLhenC/uFweMC8YJ44ZxxLhinDHuGIeMS8Yp'
    '45ZxzLhmnDPuGQeNi8ZJ46Zx1LhqnDXuGoeNy8Zp47Zx3LhunDfuGweOC8eJ48Zx5LhynDnuHIeOS8ep49Zx7Lh2nDvuHQeP'
    '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'
))))
