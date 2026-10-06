"""spc700.py - the SNES's sound CPU (Sony SPC700), as a model for the RTL to be checked against.

From Fullsnes's SPC700 chapter; checked against the SingleStepTests spc700 suite
(tools/snes/spctest.py). 64 kB address space, bus by callback; `cycles` counts every cycle
(reads, writes and the chip's internal ones) as the suite lists them.
"""

C, Z, I, H, B, P, V, N = 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80


class SPC:
    def __init__(self, read, write):
        self.rd, self.wr = read, write
        self.a = self.x = self.y = 0
        self.sp = 0xEF
        self.pc = 0
        self.psw = 0
        self.stopped = False
        self.cycles = 0

    # --- the bus -----------------------------------------------------------------------------
    def r(self, a):
        self.cycles += 1
        return self.rd(a & 0xFFFF)

    def w(self, a, v):
        self.cycles += 1
        self.wr(a & 0xFFFF, v & 0xFF)

    _dummy = False

    def idle(self, n=1):
        if self._dummy:                         # (the first internal cycle of a one-byte op)
            self._dummy = False
            self.r(self.pc)
            n -= 1
        self.cycles += n

    def fetch(self):
        v = self.r(self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        return v

    def fetch16(self):
        lo = self.fetch()
        return lo | (self.fetch() << 8)

    # --- the direct page ----------------------------------------------------------------------
    def dp(self, o):
        return (0x100 if self.psw & P else 0) | (o & 0xFF)

    def rdp(self, o): return self.r(self.dp(o))
    def wdp(self, o, v): self.w(self.dp(o), v)

    def rdp16(self, o):
        lo = self.rdp(o)
        return lo | (self.rdp(o + 1) << 8)

    # --- flags -----------------------------------------------------------------------------
    def nz(self, v):
        v &= 0xFF
        self.psw = (self.psw & ~(N | Z)) | (v & 0x80) | (Z if v == 0 else 0)
        return v

    def nz16(self, v):
        v &= 0xFFFF
        self.psw = (self.psw & ~(N | Z)) | ((v >> 8) & 0x80) | (Z if v == 0 else 0)
        return v

    def setf(self, f, on):
        self.psw = (self.psw | f) if on else (self.psw & ~f)

    # --- the stack (page 1) ---------------------------------------------------------------------
    def push(self, v):
        self.w(0x100 | self.sp, v)
        self.sp = (self.sp - 1) & 0xFF

    def pop(self):
        self.sp = (self.sp + 1) & 0xFF
        return self.r(0x100 | self.sp)

    # --- arithmetic -------------------------------------------------------------------------
    def adc(self, a, b):
        c = self.psw & C
        r = a + b + c
        self.setf(C, r > 0xFF)
        self.setf(V, ~(a ^ b) & (a ^ r) & 0x80)
        self.setf(H, ((a & 0x0F) + (b & 0x0F) + c) > 0x0F)
        return self.nz(r)

    def sbc(self, a, b):
        return self.adc(a, b ^ 0xFF)

    def cmp(self, a, b):
        r = a - b
        self.setf(C, r >= 0)
        self.nz(r)

    def asl(self, v): self.setf(C, v & 0x80); return self.nz(v << 1)
    def lsr(self, v): self.setf(C, v & 1); return self.nz(v >> 1)
    def rol(self, v):
        c = self.psw & C; self.setf(C, v & 0x80); return self.nz((v << 1) | c)
    def ror(self, v):
        c = self.psw & C; self.setf(C, v & 1); return self.nz((v >> 1) | (c << 7))

    # --- operand addresses ------------------------------------------------------------------
    # (each returns a 16-bit address; the d+X forms wrap within the page)
    def a_d(self): return self.dp(self.fetch())
    def a_dx(self): o = self.fetch(); self.idle(); return self.dp(o + self.x)
    def a_dy(self): o = self.fetch(); self.idle(); return self.dp(o + self.y)
    def a_abs(self): return self.fetch16()
    def a_absx(self): a = self.fetch16(); self.idle(); return (a + self.x) & 0xFFFF
    def a_absy(self): a = self.fetch16(); self.idle(); return (a + self.y) & 0xFFFF
    def a_xi(self): self.idle(); return self.dp(self.x)                 # (X)
    def a_dxi(self):                                                    # [d+X]
        o = self.fetch(); self.idle()
        lo = self.rdp(o + self.x)
        return lo | (self.rdp(o + self.x + 1) << 8)
    def a_diy(self):                                                    # [d]+Y
        o = self.fetch()
        self.idle()
        p = self.rdp(o) | (self.rdp(o + 1) << 8)
        return (p + self.y) & 0xFFFF

    def a_diy_st(self):                                                 # [d]+Y, storing: the
        o = self.fetch()                                                # internal cycle comes
        p = self.rdp(o) | (self.rdp(o + 1) << 8)                        # after the pointer
        self.idle()
        return (p + self.y) & 0xFFFF

    def step(self):
        if self.stopped:
            self.r(self.pc)                     # (asleep: the next byte read again and again)
            self.idle()
            return
        op = self.fetch()
        # a one-byte instruction spends its first cycle reading the byte after it
        self._dummy = op in SINGLE
        OPS[op](self)
        self._dummy = False


OPS = [None] * 256
# the one-byte instructions (their first internal cycle reads the next byte)
SINGLE = {0xFE, 0x00, 0x01, 0x06, 0x0D, 0x0F, 0x11, 0x19, 0x1C, 0x1D, 0x20, 0x21, 0x26, 0x2D, 0x31, 0x39, 0x3C, 0x3D, 0x40, 0x41, 0x46, 0x4D, 0x51, 0x59, 0x5C, 0x5D, 0x60, 0x61, 0x66, 0x6D, 0x6F, 0x71, 0x79, 0x7C, 0x7D, 0x7F, 0x80, 0x81, 0x86, 0x8E, 0x91, 0x99, 0x9C, 0x9D, 0x9E, 0x9F, 0xA0, 0xA1, 0xA6, 0xAE, 0xAF, 0xB1, 0xB9, 0xBC, 0xBD, 0xBE, 0xBF, 0xC0, 0xC1, 0xC6, 0xCE, 0xCF, 0xD1, 0xDC, 0xDD, 0xDF, 0xE0, 0xE1, 0xE6, 0xED, 0xEE, 0xEF, 0xF1, 0xFC, 0xFD, 0xFF}


def op(code):
    def reg(fn):
        OPS[code] = fn
        return fn
    return reg


# --- the eight ALU groups: OR AND EOR CMP ADC SBC (rows 0, 2, 4, 6, 8, A) ---------------------------
def _alu(c, kind, a, b):
    if kind == 0: return c.nz(a | b)
    if kind == 1: return c.nz(a & b)
    if kind == 2: return c.nz(a ^ b)
    if kind == 3: c.cmp(a, b); return None
    if kind == 4: return c.adc(a, b)
    if kind == 5: return c.sbc(a, b)


for kind, row in enumerate((0x00, 0x20, 0x40, 0x60, 0x80, 0xA0)):
    def mk(kind, addr_fn, imm=False):
        def f(c):
            v = c.fetch() if imm else c.r(addr_fn(c))
            r = _alu(c, kind, c.a, v)
            if r is not None:
                c.a = r
        return f
    OPS[row | 0x04] = mk(kind, SPC.a_d)
    OPS[row | 0x05] = mk(kind, SPC.a_abs)
    OPS[row | 0x06] = mk(kind, SPC.a_xi)
    OPS[row | 0x07] = mk(kind, SPC.a_dxi)
    OPS[row | 0x08] = mk(kind, None, True)
    OPS[row | 0x14] = mk(kind, SPC.a_dx)
    OPS[row | 0x15] = mk(kind, SPC.a_absx)
    OPS[row | 0x16] = mk(kind, SPC.a_absy)
    OPS[row | 0x17] = mk(kind, SPC.a_diy)

    def dd_ds(kind):
        def f(c):
            s = c.rdp(c.fetch())
            d = c.fetch()
            v = c.rdp(d)
            r = _alu(c, kind, v, s)
            if r is not None: c.wdp(d, r)
            else: c.idle()
        return f

    def d_imm(kind):
        def f(c):
            s = c.fetch()
            d = c.fetch()
            v = c.rdp(d)
            r = _alu(c, kind, v, s)
            if r is not None: c.wdp(d, r)
            else: c.idle()
        return f

    def xy(kind):
        def f(c):
            c.idle()
            s = c.rdp(c.y)
            v = c.rdp(c.x)
            r = _alu(c, kind, v, s)
            if r is not None: c.wdp(c.x, r)
            else: c.idle()
        return f
    OPS[row | 0x09] = dd_ds(kind)
    OPS[row | 0x18] = d_imm(kind)
    OPS[row | 0x19] = xy(kind)


# --- shifts, INC, DEC on memory and A ------------------------------------------------------------
def _rmw(fn_name, addr_fn):
    def f(c):
        a = addr_fn(c)
        v = c.r(a)
        c.w(a, getattr(c, fn_name)(v) if fn_name not in ('inc', 'dec') else
            c.nz(v + (1 if fn_name == 'inc' else -1)))
    return f


for name, base in (('asl', 0x00), ('rol', 0x20), ('lsr', 0x40), ('ror', 0x60)):
    OPS[base | 0x0B] = _rmw(name, SPC.a_d)
    OPS[base | 0x0C] = _rmw(name, SPC.a_abs)
    OPS[base | 0x1B] = _rmw(name, SPC.a_dx)
    OPS[base | 0x1C] = (lambda n: lambda c: (c.idle(), setattr(c, 'a', getattr(c, n)(c.a))))(name)
OPS[0x8B] = _rmw('dec', SPC.a_d); OPS[0x8C] = _rmw('dec', SPC.a_abs); OPS[0x9B] = _rmw('dec', SPC.a_dx)
OPS[0xAB] = _rmw('inc', SPC.a_d); OPS[0xAC] = _rmw('inc', SPC.a_abs); OPS[0xBB] = _rmw('inc', SPC.a_dx)
OPS[0x9C] = lambda c: (c.idle(), setattr(c, 'a', c.nz(c.a - 1)))
OPS[0xBC] = lambda c: (c.idle(), setattr(c, 'a', c.nz(c.a + 1)))
OPS[0x1D] = lambda c: (c.idle(), setattr(c, 'x', c.nz(c.x - 1)))
OPS[0x3D] = lambda c: (c.idle(), setattr(c, 'x', c.nz(c.x + 1)))
OPS[0xDC] = lambda c: (c.idle(), setattr(c, 'y', c.nz(c.y - 1)))
OPS[0xFC] = lambda c: (c.idle(), setattr(c, 'y', c.nz(c.y + 1)))


# --- compares on X and Y ---------------------------------------------------------------------
OPS[0x1E] = lambda c: c.cmp(c.x, c.r(c.a_abs()))
OPS[0x3E] = lambda c: c.cmp(c.x, c.r(c.a_d()))
OPS[0xC8] = lambda c: c.cmp(c.x, c.fetch())
OPS[0x5E] = lambda c: c.cmp(c.y, c.r(c.a_abs()))
OPS[0x7E] = lambda c: c.cmp(c.y, c.r(c.a_d()))
OPS[0xAD] = lambda c: c.cmp(c.y, c.fetch())


# --- moves -----------------------------------------------------------------------------------
def _ld(reg, addr_fn=None, imm=False, post_inc=False):
    def f(c):
        if imm:
            v = c.fetch()
        else:
            a = addr_fn(c)
            v = c.r(a)
        setattr(c, reg, c.nz(v))
        if post_inc:
            c.idle(); c.x = (c.x + 1) & 0xFF
    return f


def _st(reg, addr_fn):
    def f(c):
        a = addr_fn(c)
        c.r(a)                                  # (a store reads its address first)
        c.w(a, getattr(c, reg))
    return f


OPS[0xE4] = _ld('a', SPC.a_d); OPS[0xE5] = _ld('a', SPC.a_abs); OPS[0xE6] = _ld('a', SPC.a_xi)
OPS[0xE7] = _ld('a', SPC.a_dxi); OPS[0xE8] = _ld('a', imm=True); OPS[0xF4] = _ld('a', SPC.a_dx)
OPS[0xF5] = _ld('a', SPC.a_absx); OPS[0xF6] = _ld('a', SPC.a_absy); OPS[0xF7] = _ld('a', SPC.a_diy)
OPS[0xBF] = _ld('a', SPC.a_xi, post_inc=True)
OPS[0xCD] = _ld('x', imm=True); OPS[0xF8] = _ld('x', SPC.a_d); OPS[0xF9] = _ld('x', SPC.a_dy); OPS[0xE9] = _ld('x', SPC.a_abs)
OPS[0x8D] = _ld('y', imm=True); OPS[0xEB] = _ld('y', SPC.a_d); OPS[0xFB] = _ld('y', SPC.a_dx); OPS[0xEC] = _ld('y', SPC.a_abs)
OPS[0xC4] = _st('a', SPC.a_d); OPS[0xC5] = _st('a', SPC.a_abs); OPS[0xC6] = _st('a', SPC.a_xi)
OPS[0xC7] = _st('a', SPC.a_dxi); OPS[0xD4] = _st('a', SPC.a_dx); OPS[0xD5] = _st('a', SPC.a_absx)
OPS[0xD6] = _st('a', SPC.a_absy); OPS[0xD7] = _st('a', SPC.a_diy_st)
OPS[0xD8] = _st('x', SPC.a_d); OPS[0xD9] = _st('x', SPC.a_dy); OPS[0xC9] = _st('x', SPC.a_abs)
OPS[0xCB] = _st('y', SPC.a_d); OPS[0xDB] = _st('y', SPC.a_dx); OPS[0xCC] = _st('y', SPC.a_abs)


@op(0xAF)
def _mov_xinc_a(c):                             # MOV (X)+,A
    c.idle(2)
    c.wdp(c.x, c.a)
    c.x = (c.x + 1) & 0xFF


@op(0x8F)
def _mov_d_imm(c):
    v = c.fetch(); d = c.fetch()
    c.rdp(d)
    c.wdp(d, v)


@op(0xFA)
def _mov_dd_ds(c):
    v = c.rdp(c.fetch())
    c.wdp(c.fetch(), v)


OPS[0x5D] = lambda c: (c.idle(), setattr(c, 'x', c.nz(c.a)))       # MOV X,A
OPS[0x7D] = lambda c: (c.idle(), setattr(c, 'a', c.nz(c.x)))       # MOV A,X
OPS[0xDD] = lambda c: (c.idle(), setattr(c, 'a', c.nz(c.y)))       # MOV A,Y
OPS[0xFD] = lambda c: (c.idle(), setattr(c, 'y', c.nz(c.a)))       # MOV Y,A
OPS[0x9D] = lambda c: (c.idle(), setattr(c, 'x', c.nz(c.sp)))      # MOV X,SP
OPS[0xBD] = lambda c: (c.idle(), setattr(c, 'sp', c.x))            # MOV SP,X


# --- 16-bit -------------------------------------------------------------------------------
@op(0xBA)
def _movw_ya_d(c):
    d = c.fetch()
    lo = c.rdp(d); c.idle(); hi = c.rdp(d + 1)
    c.a, c.y = lo, hi
    c.nz16(lo | (hi << 8))


@op(0xDA)
def _movw_d_ya(c):
    d = c.fetch()
    c.rdp(d)
    c.wdp(d, c.a); c.wdp(d + 1, c.y)


def _w16(c, d):
    lo = c.rdp(d); c.idle(); hi = c.rdp(d + 1)
    return lo | (hi << 8)


@op(0x3A)
def _incw(c):
    d = c.fetch()
    v = (c.rdp(d) + 1)
    c.wdp(d, v & 0xFF)
    hi = c.rdp(d + 1)
    w = ((hi << 8) + v) & 0xFFFF
    c.wdp(d + 1, w >> 8)
    c.nz16(w)


@op(0x1A)
def _decw(c):
    d = c.fetch()
    lo = c.rdp(d)
    w0 = lo - 1
    c.wdp(d, w0 & 0xFF)
    hi = c.rdp(d + 1)
    w = ((hi << 8) + w0) & 0xFFFF
    c.wdp(d + 1, w >> 8)
    c.nz16(w)


@op(0x7A)
def _addw(c):
    d = c.fetch()
    v = _w16(c, d)
    ya = (c.y << 8) | c.a
    r = ya + v
    c.setf(C, r > 0xFFFF)
    c.setf(V, ~(ya ^ v) & (ya ^ r) & 0x8000)
    c.setf(H, ((ya & 0x0FFF) + (v & 0x0FFF)) > 0x0FFF)
    r &= 0xFFFF
    c.a, c.y = r & 0xFF, r >> 8
    c.nz16(r)


@op(0x9A)
def _subw(c):
    d = c.fetch()
    v = _w16(c, d)
    ya = (c.y << 8) | c.a
    r = ya - v
    c.setf(C, r >= 0)
    c.setf(V, (ya ^ v) & (ya ^ r) & 0x8000)
    c.setf(H, ((ya & 0x0FFF) - (v & 0x0FFF)) >= 0)
    r &= 0xFFFF
    c.a, c.y = r & 0xFF, r >> 8
    c.nz16(r)


@op(0x5A)
def _cmpw(c):
    d = c.fetch()
    lo = c.rdp(d); hi = c.rdp(d + 1)
    v = lo | (hi << 8)
    r = ((c.y << 8) | c.a) - v
    c.setf(C, r >= 0)
    c.nz16(r)


@op(0xCF)
def _mul(c):
    c.idle(8)
    r = c.y * c.a
    c.a, c.y = r & 0xFF, r >> 8
    c.nz(c.y)


@op(0x9E)
def _div(c):
    c.idle(11)
    ya = (c.y << 8) | c.a
    x = c.x
    c.setf(V, c.y >= x)
    c.setf(H, (c.y & 0x0F) >= (x & 0x0F))
    if c.y < (x << 1):
        q, rem = (ya // x, ya % x) if x else (0xFF, ya & 0xFF)  # (x = 0 only reaches here when y = 0)
        if x == 0:
            q, rem = 0x1FF, c.a
        c.a, c.y = q & 0xFF, rem & 0xFF
    else:
        t = ya - (x << 9)
        q = 255 - t // (256 - x)
        rem = x + t % (256 - x)
        c.a, c.y = q & 0xFF, rem & 0xFF
    c.nz(c.a)


@op(0xDF)
def _daa(c):
    c.idle(2)
    a = c.a
    if (c.psw & C) or a > 0x99:
        a += 0x60; c.setf(C, True)
    if (c.psw & H) or (a & 0x0F) > 9:
        a += 6
    c.a = c.nz(a)


@op(0xBE)
def _das(c):
    c.idle(2)
    a = c.a
    if not (c.psw & C) or a > 0x99:
        a -= 0x60; c.setf(C, False)
    if not (c.psw & H) or (a & 0x0F) > 9:
        a -= 6
    c.a = c.nz(a)


@op(0x9F)
def _xcn(c):
    c.idle(4)
    c.a = c.nz(((c.a << 4) | (c.a >> 4)) & 0xFF)


# --- bits ------------------------------------------------------------------------------------
for b in range(8):
    def set1(b, on):
        def f(c):
            d = c.fetch()
            v = c.rdp(d)
            c.wdp(d, (v | (1 << b)) if on else (v & ~(1 << b)))
        return f

    def bb(b, on):
        def f(c):
            d = c.fetch()
            v = c.rdp(d)
            c.idle()
            off = c.fetch()
            if bool(v & (1 << b)) == on:
                c.idle(2)
                c.pc = (c.pc + (off - 256 if off & 0x80 else off)) & 0xFFFF
        return f
    OPS[(b << 5) | 0x02] = set1(b, True)
    OPS[(b << 5) | 0x12] = set1(b, False)
    OPS[(b << 5) | 0x03] = bb(b, True)
    OPS[(b << 5) | 0x13] = bb(b, False)


def _mb(c):
    w = c.fetch16()
    return w & 0x1FFF, w >> 13


def _bit1(kind, invert=False):
    def f(c):
        a, b = _mb(c)
        bit = (c.r(a) >> b) & 1
        if invert:
            bit ^= 1
        cf = c.psw & C
        if kind == 'and':
            c.setf(C, cf & bit)
        elif kind == 'or':
            c.idle(); c.setf(C, cf | bit)
        elif kind == 'eor':
            c.idle(); c.setf(C, cf ^ bit)
        elif kind == 'mov':
            c.setf(C, bit)
    return f


OPS[0x4A] = _bit1('and'); OPS[0x6A] = _bit1('and', True)
OPS[0x0A] = _bit1('or'); OPS[0x2A] = _bit1('or', True)
OPS[0x8A] = _bit1('eor'); OPS[0xAA] = _bit1('mov')


@op(0xCA)
def _mov1_mb_c(c):
    a, b = _mb(c)
    v = c.r(a)
    c.idle()
    v = (v | (1 << b)) if (c.psw & C) else (v & ~(1 << b))
    c.w(a, v)


@op(0xEA)
def _not1(c):
    a, b = _mb(c)
    v = c.r(a)
    c.w(a, v ^ (1 << b))


@op(0x0E)
def _tset1(c):
    a = c.fetch16()
    v = c.r(a)
    c.nz(c.a - v)
    c.r(a)
    c.w(a, v | c.a)


@op(0x4E)
def _tclr1(c):
    a = c.fetch16()
    v = c.r(a)
    c.nz(c.a - v)
    c.r(a)
    c.w(a, v & ~c.a)


# --- branches, jumps, calls ------------------------------------------------------------------
def _br(cond):
    def f(c):
        off = c.fetch()
        if cond(c):
            c.idle(2)
            c.pc = (c.pc + (off - 256 if off & 0x80 else off)) & 0xFFFF
    return f


OPS[0x10] = _br(lambda c: not c.psw & N); OPS[0x30] = _br(lambda c: c.psw & N)
OPS[0x50] = _br(lambda c: not c.psw & V); OPS[0x70] = _br(lambda c: c.psw & V)
OPS[0x90] = _br(lambda c: not c.psw & C); OPS[0xB0] = _br(lambda c: c.psw & C)
OPS[0xD0] = _br(lambda c: not c.psw & Z); OPS[0xF0] = _br(lambda c: c.psw & Z)
OPS[0x2F] = _br(lambda c: True)


@op(0x2E)
def _cbne_d(c):
    d = c.fetch()
    v = c.rdp(d)
    c.idle()
    off = c.fetch()
    if v != c.a:
        c.idle(2)
        c.pc = (c.pc + (off - 256 if off & 0x80 else off)) & 0xFFFF


@op(0xDE)
def _cbne_dx(c):
    d = c.fetch()
    c.idle()
    v = c.rdp(d + c.x)
    c.idle()
    off = c.fetch()
    if v != c.a:
        c.idle(2)
        c.pc = (c.pc + (off - 256 if off & 0x80 else off)) & 0xFFFF


@op(0x6E)
def _dbnz_d(c):
    d = c.fetch()
    v = (c.rdp(d) - 1) & 0xFF
    c.wdp(d, v)
    off = c.fetch()
    if v:
        c.idle(2)
        c.pc = (c.pc + (off - 256 if off & 0x80 else off)) & 0xFFFF


@op(0xFE)
def _dbnz_y(c):
    c.idle()
    c.y = (c.y - 1) & 0xFF
    c.idle()
    off = c.fetch()
    if c.y:
        c.idle(2)
        c.pc = (c.pc + (off - 256 if off & 0x80 else off)) & 0xFFFF


OPS[0x5F] = lambda c: setattr(c, 'pc', c.fetch16())                 # JMP !a


@op(0x1F)
def _jmp_absx(c):
    a = (c.fetch16() + c.x) & 0xFFFF
    c.idle()
    c.pc = c.r(a) | (c.r((a + 1) & 0xFFFF) << 8)


def _call_to(c, target):
    c.push(c.pc >> 8)
    c.push(c.pc & 0xFF)
    c.pc = target


@op(0x3F)
def _call(c):
    t = c.fetch16()
    c.idle()
    _call_to(c, t)
    c.idle(2)


@op(0x4F)
def _pcall(c):
    u = c.fetch()
    c.idle()
    _call_to(c, 0xFF00 | u)
    c.idle()


for n in range(16):
    def tcall(n):
        def f(c):
            c.idle(2)
            _call_to(c, 0)
            c.idle()
            a = 0xFFDE - 2 * n
            c.pc = c.r(a) | (c.r(a + 1) << 8)
        return f
    OPS[(n << 4) | 0x01] = tcall(n)


@op(0x0F)
def _brk(c):
    c.idle()
    c.push(c.pc >> 8); c.push(c.pc & 0xFF); c.push(c.psw)
    c.idle()
    c.pc = c.r(0xFFDE) | (c.r(0xFFDF) << 8)
    c.psw = (c.psw | B) & ~I


@op(0x6F)
def _ret(c):
    c.idle(2)
    lo = c.pop()
    c.pc = lo | (c.pop() << 8)


@op(0x7F)
def _reti(c):
    c.idle(2)
    c.psw = c.pop()
    lo = c.pop()
    c.pc = lo | (c.pop() << 8)


# --- the stack and the flags ---------------------------------------------------------------
OPS[0x2D] = lambda c: (c.idle(), c.push(c.a), c.idle())
OPS[0x4D] = lambda c: (c.idle(), c.push(c.x), c.idle())
OPS[0x6D] = lambda c: (c.idle(), c.push(c.y), c.idle())
OPS[0x0D] = lambda c: (c.idle(), c.push(c.psw), c.idle())
OPS[0xAE] = lambda c: (c.idle(), c.idle(), setattr(c, 'a', c.pop()))
OPS[0xCE] = lambda c: (c.idle(), c.idle(), setattr(c, 'x', c.pop()))
OPS[0xEE] = lambda c: (c.idle(), c.idle(), setattr(c, 'y', c.pop()))
OPS[0x8E] = lambda c: (c.idle(), c.idle(), setattr(c, 'psw', c.pop()))
OPS[0x20] = lambda c: (c.idle(), c.setf(P, False))
OPS[0x40] = lambda c: (c.idle(), c.setf(P, True))
OPS[0x60] = lambda c: (c.idle(), c.setf(C, False))
OPS[0x80] = lambda c: (c.idle(), c.setf(C, True))
OPS[0xE0] = lambda c: (c.idle(), c.setf(V | H, False))
OPS[0xED] = lambda c: (c.idle(2), c.setf(C, not c.psw & C))
OPS[0xA0] = lambda c: (c.idle(2), c.setf(I, True))
OPS[0xC0] = lambda c: (c.idle(2), c.setf(I, False))
OPS[0x00] = lambda c: c.idle()                                     # NOP
def _sleep(c):                          # SLEEP / STOP: reading the next byte over and over
    c.idle(2)
    for _ in range(2):
        c.r(c.pc)
        c.idle()
    c.stopped = True


OPS[0xEF] = _sleep
OPS[0xFF] = _sleep

missing = [hex(i) for i, f in enumerate(OPS) if f is None]
assert not missing, missing
