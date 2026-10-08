"""mdec.py - the PlayStation's MDEC (motion decoder) as a model, for rtl/ps1_mdec.v to be checked
against. From docs/MDEC_NOTES.md: Mednafen's arithmetic (the most hardware-tested; its sections
3.3, 4.2, 5.1), and the output as the FPGA gives it -- a whole macroblock buffered and handed out
row by row (what DMA1's re-ordering makes of the chip's 8x8 order), so DMA1 is a linear copy.

    m = Mdec(); m.write0(word) ... ; m.read0() -> word     (1F801820h: commands/parameters, data out)
    m.status() / m.write1(v)                                 (1F801824h)

    python tools/ps1/mdec.py selftest     the worked examples of MDEC_NOTES section 8
"""
import sys

ZAGZIG = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
          12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
          35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
          58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63]

# the scale table games upload (MDEC(3)), row f = frequency, column p = pixel
STD_SCALE = [
    [0x5A82] * 8,
    [0x7D8A, 0x6A6D, 0x471C, 0x18F8, 0xE707, 0xB8E3, 0x9592, 0x8275],
    [0x7641, 0x30FB, 0xCF04, 0x89BE, 0x89BE, 0xCF04, 0x30FB, 0x7641],
    [0x6A6D, 0xE707, 0x8275, 0xB8E3, 0x471C, 0x7D8A, 0x18F8, 0x9592],
    [0x5A82, 0xA57D, 0xA57D, 0x5A82, 0x5A82, 0xA57D, 0xA57D, 0x5A82],
    [0x471C, 0x8275, 0x18F8, 0x6A6D, 0x9592, 0xE707, 0x7D8A, 0xB8E3],
    [0x30FB, 0x89BE, 0x7641, 0xCF04, 0xCF04, 0x7641, 0x89BE, 0x30FB],
    [0x18F8, 0xB8E3, 0x6A6D, 0x8275, 0x7D8A, 0x9592, 0x471C, 0xE707]]
STD_QUANT = bytes.fromhex(
    '02101013101316161616161616' '1A181A1B1B1B1A1A1A1A1B1B1B1D1D1D2222221D'
    '1D1D1B1B1D1D2020222225262523232223262628282830302E2E38383A454553')


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def s10(v):
    v &= 0x3FF
    return v - 0x400 if v & 0x200 else v


def wrap9_clamp(v):
    """the low 9 bits as signed, then clamped to a signed byte"""
    v &= 0x1FF
    if v & 0x100:
        v -= 0x200
    return -128 if v < -128 else 127 if v > 127 else v


def dequant(level, k, qscale, qt):
    """a coefficient into the IDCT's 15-bit input (4 fraction bits)"""
    q = qt[0] if k == 0 else qscale * qt[k]
    if q == 0:
        c = 32 * level
    else:
        p = (level * q) >> 3 if k else level * q
        c = 16 * p - 8 if level > 0 else 16 * p + 8 if level < 0 else 0
    return -0x4000 if c < -0x4000 else 0x3FFF if c > 0x3FFF else c


def idct(c, scale):
    """an 8x8 block (row = vertical frequency) to signed 8-bit pixels (row = y)"""
    m = [[s16(scale[f][p]) >> 3 for p in range(8)] for f in range(8)]
    t = [[0] * 8 for _ in range(8)]                       # t[y][u]
    for u in range(8):
        for y in range(8):
            s = sum(c[v * 8 + u] * m[v][y] for v in range(8))
            t[y][u] = s16((s + 0x4000) >> 15)
    out = [0] * 64
    for y in range(8):
        for x in range(8):
            s = sum(t[y][u] * m[u][x] for u in range(8))
            out[y * 8 + x] = wrap9_clamp((s + 0x4000) >> 15)
    return out


def rgb(yv, cb, cr):
    r = yv + ((359 * cr + 0x80) >> 8)
    g = yv + ((((-88 * cb) & ~0x1F) + ((-183 * cr) & ~0x07) + 0x80) >> 8)
    b = yv + ((454 * cb + 0x80) >> 8)
    return wrap9_clamp(r), wrap9_clamp(g), wrap9_clamp(b)


def to15(r, g, b, signed, bit15):
    """the signed bytes to a 15-bit pixel (from the unsigned values, rounded)"""
    f = lambda v: min(31, ((v ^ 0x80) & 0xFF) + 4 >> 3)
    w = f(r) | f(g) << 5 | f(b) << 10 | (bit15 << 15)
    return w ^ 0x4210 if signed else w


def rgb_frac(yv, cb, cr):
    """the same sums in 1/256ths, before any rounding"""
    return (yv * 256 + 359 * cr,
            yv * 256 + ((-88 * cb) & ~0x1F) + ((-183 * cr) & ~0x07),
            yv * 256 + 454 * cb)


def to15f(r, g, b, signed, bit15):
    """15-bit from the unrounded sums: + 128 and half a step, the top five bits, clamped"""
    f = lambda v: max(0, min(31, (v + 0x8400) >> 11))
    w = f(r) | f(g) << 5 | f(b) << 10 | (bit15 << 15)
    return w ^ 0x4210 if signed else w


class Mdec:
    def __init__(self):
        self.qt_y = [0] * 64
        self.qt_c = [0] * 64
        self.scale = [[0] * 8 for _ in range(8)]
        self.reset()

    def reset(self):
        self.out = []                     # the data-out FIFO, words (unbounded here)
        self.cmd = None                   # the command being fed: (kind, remaining words, ...)
        self.words_left = 0
        self.depth = 0; self.signed = 0; self.bit15 = 0
        self.en_in = self.en_out = 0
        self.status_low = 0
        self._begin_mb()

    # --- 1F801824h ---------------------------------------------------------------------------
    def write1(self, v):
        if v & 0x80000000:
            q = (self.qt_y, self.qt_c, self.scale)
            self.reset()
            self.qt_y, self.qt_c, self.scale = q
        self.en_in = (v >> 30) & 1
        self.en_out = (v >> 29) & 1

    def status(self):
        busy = self.cmd is not None
        rem = (self.words_left - 1) & 0xFFFF if busy and self.cmd == 'dec' else 0xFFFF if busy else 0
        return ((not self.out) << 31 | busy << 29 | (self.en_in and busy) << 28 |
                (self.en_out and len(self.out) > 0) << 27 | self.depth << 25 | self.signed << 24 |
                self.bit15 << 23 | rem)

    # --- 1F801820h ---------------------------------------------------------------------------
    def read0(self):
        return self.out.pop(0) if self.out else 0xFFFFFFFF

    def write0(self, w):
        if self.cmd is None:
            op = w >> 29
            self.depth, self.signed, self.bit15 = (w >> 27) & 3, (w >> 26) & 1, (w >> 25) & 1
            if op == 1:
                self.cmd, self.words_left = 'dec', w & 0xFFFF
                self._begin_mb()
            elif op == 2:
                self.cmd, self.words_left, self.tbl, self.tbl_i = 'qt', 32 if w & 1 else 16, w & 1, 0
            elif op == 3:
                self.cmd, self.words_left, self.tbl_i = 'sc', 32, 0
            if self.cmd is not None and self.words_left == 0:
                self.cmd = None
            return
        if self.cmd == 'dec':
            self._half(w & 0xFFFF)
            self._half(w >> 16)
        elif self.cmd == 'qt':
            for b in range(4):
                i = self.tbl_i * 4 + b
                (self.qt_y if i < 64 else self.qt_c)[i & 63] = (w >> (8 * b)) & 0xFF
            self.tbl_i += 1
        elif self.cmd == 'sc':
            for h in range(2):
                i = self.tbl_i * 2 + h
                self.scale[i >> 3][i & 7] = (w >> (16 * h)) & 0xFFFF
            self.tbl_i += 1
        self.words_left -= 1
        if self.words_left == 0:
            self.cmd = None

    # --- decoding ----------------------------------------------------------------------------
    def _mono(self):
        return self.depth < 2

    def _begin_mb(self):
        self.blk = 0                      # colour: 0 Cr 1 Cb 2..5 Y1..Y4; mono: always the one Y
        self.k = -1                       # -1: the next halfword is a DC
        self.coef = [0] * 64
        self.blocks = {}

    def _half(self, h):
        if self.k < 0:
            if h == 0xFE00:
                return                    # (padding between blocks)
            self.qscale = h >> 10
            self.coef = [0] * 64
            self.k = 0
            self._store(0, s10(h))
        else:
            self.k += (h >> 10) + 1
            if self.k <= 63:
                self._store(self.k, s10(h))
            if self.k >= 63:
                self._end_block()

    def _store(self, k, level):
        mono = self._mono()
        qt = self.qt_y if (mono or self.blk >= 2) else self.qt_c
        self.coef[ZAGZIG[k]] = dequant(level, k, self.qscale, qt)
        if k == 63:
            pass

    def _end_block(self):
        px = idct(self.coef, self.scale)
        self.k = -1
        if self._mono():
            self._emit_mono(px)
            return
        self.blocks[self.blk] = px
        self.blk += 1
        if self.blk == 6:
            self._emit_colour()
            self._begin_mb()

    def _emit_mono(self, px):
        if self.depth == 1:               # 8-bit: 4 a word
            vals = [(v ^ 0x80) & 0xFF if not self.signed else v & 0xFF for v in px]
            for i in range(0, 64, 4):
                self.out.append(vals[i] | vals[i + 1] << 8 | vals[i + 2] << 16 | vals[i + 3] << 24)
        else:                             # 4-bit: 8 a word
            nib = []
            for v in px:
                n = min(127, v + 8) >> 4 & 15
                nib.append(n ^ 8 if not self.signed else n)
            for i in range(0, 64, 8):
                w = 0
                for j in range(8):
                    w |= nib[i + j] << (4 * j)
                self.out.append(w)

    def _emit_colour(self):
        cr, cb = self.blocks[0], self.blocks[1]
        # the 16x16 macroblock as the chip sends it: Y1 Y2 Y3 Y4, 8x8 each, row by row
        # (DMA1 puts them in 16-pixel rows as it writes RAM; the port gives them as they are)
        pix = []; fpix = []
        for b in range(4):
            for yy in range(8):
                for xx in range(8):
                    y = (b >> 1) * 8 + yy; x = (b & 1) * 8 + xx
                    yb = self.blocks[2 + (y >> 3) * 2 + (x >> 3)]
                    yv = yb[(y & 7) * 8 + (x & 7)]
                    c = (y >> 1) * 8 + (x >> 1)
                    pix.append(rgb(yv, cb[c], cr[c]))
                    fpix.append(rgb_frac(yv, cb[c], cr[c]))
        if self.depth == 3:               # 15-bit: two a word, rounded once from the fraction
            hw = [to15f(*f, self.signed, self.bit15) for f in fpix]
            for i in range(0, 256, 2):
                self.out.append(hw[i] | hw[i + 1] << 16)
        else:                             # 24-bit: R G B bytes, packed
            bs = []
            for r, g, b in pix:
                for v in (r, g, b):
                    bs.append((v ^ 0x80) & 0xFF if not self.signed else v & 0xFF)
            for i in range(0, len(bs), 4):
                self.out.append(bs[i] | bs[i + 1] << 8 | bs[i + 2] << 16 | bs[i + 3] << 24)


def selftest():
    ok = True
    sc = STD_SCALE
    qt = [2] + [16] * 63
    for dc, want in ((1, 0), (3, 1), (10, 2), (100, 25), (-100, -25), (200, 50), (511, 127), (-512, -128)):
        c = [0] * 64
        c[0] = dequant(dc, 0, 0, qt)
        got = idct(c, sc)
        if any(v != want for v in got):
            print('DC %d: got %s, want %d' % (dc, got[:4], want)); ok = False
    c = [0] * 64
    c[0] = dequant(40, 0, 10, qt); c[ZAGZIG[1]] = dequant(5, 1, 10, qt)
    got = idct(c, sc)
    if got[:8] != [27, 25, 20, 13, 6, 0, -5, -7] or got[8:16] != got[:8]:
        print('DC+AC: got', got[:8]); ok = False
    r, g, b = rgb(50, -20, 30)
    if (r, g, b) != (92, 35, 15):
        print('rgb', (r, g, b)); ok = False
    if to15(92, 35, 15, 0, 0) != 0x4A9C or to15(92, 35, 15, 0, 1) != 0xCA9C or to15(92, 35, 15, 1, 0) != 0x088C:
        print('to15', hex(to15(92, 35, 15, 0, 0))); ok = False
    if rgb(127, 127, 0) != (127, 83, -128) or to15(127, 83, -128, 0, 0) != 0x035F:
        print('wrap', rgb(127, 127, 0)); ok = False
    print('mdec selftest:', 'all checks passed' if ok else 'FAIL')
    return ok


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'selftest':
        sys.exit(0 if selftest() else 1)
