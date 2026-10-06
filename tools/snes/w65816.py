"""w65816.py - the SNES's CPU (the WDC 65C816), as a model for the RTL to be checked against.

Written from the WDC data sheet and Fullsnes (problemkaputt.de/fullsnes.htm), checked opcode by
opcode against the SingleStepTests 65816 suite (tools/snes/sstest.py): registers, memory and
the bus accesses of every instruction in native and emulation mode.

The bus is two callbacks on 24-bit addresses: read(addr) -> byte, write(addr, byte). Every
access the chip makes goes through them, in the chip's order -- dummy reads included -- so a
cycle list can be checked against the suite's and the SNES's memory map can count its clocks.
"""

C, Z, I, D, XF, M, V, N = 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80


class CPU:
    def __init__(self, read, write):
        self.rd, self.wr = read, write
        self.a = self.x = self.y = 0
        self.s = 0x01FF
        self.d = 0
        self.dbr = self.pbr = 0
        self.pc = 0
        self.p = M | XF | I
        self.e = 1
        self.stopped = self.waiting = False
        self.cycles = 0

    # --- the bus ---------------------------------------------------------------------------
    def r8(self, a):
        self.cycles += 1
        return self.rd(a & 0xFFFFFF)

    def w8(self, a, v):
        self.cycles += 1
        self.wr(a & 0xFFFFFF, v & 0xFF)

    def io(self):                       # an internal cycle (no access the tests see)
        self.cycles += 1

    def fetch(self):
        v = self.r8((self.pbr << 16) | self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        return v

    def fetch16(self):
        lo = self.fetch()
        return lo | (self.fetch() << 8)

    def fetch24(self):
        lo = self.fetch16()
        return lo | (self.fetch() << 16)

    # --- flags and widths ----------------------------------------------------------------
    @property
    def m8(self): return bool(self.p & M)

    @property
    def x8(self): return bool(self.p & XF)

    def setp(self, v):
        self.p = v & 0xFF
        if self.e:
            self.p |= M | XF
        if self.p & XF:
            self.x &= 0xFF
            self.y &= 0xFF

    def nz8(self, v):
        self.p = (self.p & ~(N | Z)) | (v & 0x80) | (Z if (v & 0xFF) == 0 else 0)

    def nz16(self, v):
        self.p = (self.p & ~(N | Z)) | ((v >> 8) & 0x80) | (Z if (v & 0xFFFF) == 0 else 0)

    def nzm(self, v):
        self.nz8(v) if self.m8 else self.nz16(v)

    def nzx(self, v):
        self.nz8(v) if self.x8 else self.nz16(v)

    # --- the stack -------------------------------------------------------------------------
    # (the 6502's instructions keep S in page 1 in emulation mode; the 65816's new ones --
    # PEA PEI PER PHD PLD JSL RTL PLB PHB... -- may run it out of the page and then it is
    # put back: `new` says which)
    def push(self, v, new=False):
        self.w8(self.s, v)
        if self.e and not new:
            self.s = 0x0100 | ((self.s - 1) & 0xFF)
        else:
            self.s = (self.s - 1) & 0xFFFF

    def pull(self, new=False):
        if self.e and not new:
            self.s = 0x0100 | ((self.s + 1) & 0xFF)
        else:
            self.s = (self.s + 1) & 0xFFFF
        return self.r8(self.s)

    def push16(self, v, new=False):
        self.push(v >> 8, new)
        self.push(v & 0xFF, new)

    def pull16(self, new=False):
        lo = self.pull(new)
        return lo | (self.pull(new) << 8)

    def fix_s(self):
        if self.e:
            self.s = 0x0100 | (self.s & 0xFF)

    # --- data access at the widths ---------------------------------------------------------
    def rd16(self, a, wrap=0xFFFFFF):
        """two bytes from a; the second's address wraps within `wrap` (bank 0: 0xFFFF)"""
        lo = self.r8(a)
        hi = self.r8((a & ~wrap) | ((a + 1) & wrap))
        return lo | (hi << 8)

    def wr16(self, a, v, wrap=0xFFFFFF):
        self.w8(a, v)
        self.w8((a & ~wrap) | ((a + 1) & wrap), v >> 8)

    # --- effective addresses -----------------------------------------------------------------
    # Each returns (address, wrap): wrap is the mask the second byte's address wraps in.
    def dp_base(self):
        if self.d & 0xFF:
            self.io()

    def ea_dp(self):
        o = self.fetch(); self.dp_base()
        return (self.d + o) & 0xFFFF, 0xFFFF

    def ea_dpx(self, r):
        o = self.fetch(); self.dp_base(); self.io()
        if self.e and (self.d & 0xFF) == 0:
            return (self.d & 0xFF00) | ((o + r) & 0xFF), 0x00FF if self.e else 0xFFFF
        return (self.d + o + r) & 0xFFFF, 0xFFFF

    def dp_ptr(self, a, page_wrap):
        """a 16-bit pointer at a (bank 0): the high byte wraps in the page in emulation mode
        with DL = 0 (the 6502's indirect modes)"""
        lo = self.r8(a)
        if page_wrap:
            hi = self.r8((a & 0xFF00) | ((a + 1) & 0xFF))
        else:
            hi = self.r8((a + 1) & 0xFFFF)
        return lo | (hi << 8)

    def ea_abs(self):
        return (self.dbr << 16) | self.fetch16(), 0xFFFFFF

    def ea_absx(self, r, write=False):
        base = self.fetch16()
        a = ((self.dbr << 16) | base) + r
        if write or not self.x8 or ((base & 0xFF00) != ((base + r) & 0xFF00)):
            self.r8((self.dbr << 16) | (base & 0xFF00) | ((base + r) & 0xFF)) if False else self.io()
        return a & 0xFFFFFF, 0xFFFFFF

    def ea_long(self):
        return self.fetch24(), 0xFFFFFF

    def ea_longx(self):
        return (self.fetch24() + self.x) & 0xFFFFFF, 0xFFFFFF

    def ea_ind(self):                   # (dp)
        o = self.fetch(); self.dp_base()
        pa = (self.d + o) & 0xFFFF
        p = self.dp_ptr(pa, self.e and (self.d & 0xFF) == 0)
        return (self.dbr << 16) | p, 0xFFFFFF

    def ea_indx(self):                  # (dp,X)
        # (In emulation mode the pointer's second byte always wraps within its page -- also
        # when DL is not zero and the first byte did not wrap: gilyon's cputest, from real
        # hardware, README "undocumented behavior". SingleStepTests has it unwrapped.)
        o = self.fetch(); self.dp_base(); self.io()
        if self.e:
            if (self.d & 0xFF) == 0:
                pa = (self.d & 0xFF00) | ((o + self.x) & 0xFF)
            else:
                pa = (self.d + o + self.x) & 0xFFFF
            p = self.dp_ptr(pa, True)
        else:
            pa = (self.d + o + self.x) & 0xFFFF
            p = self.dp_ptr(pa, False)
        return (self.dbr << 16) | p, 0xFFFFFF

    def ea_indy(self, write=False):     # (dp),Y
        o = self.fetch(); self.dp_base()
        pa = (self.d + o) & 0xFFFF
        p = self.dp_ptr(pa, self.e and (self.d & 0xFF) == 0)
        if write or not self.x8 or ((p & 0xFF00) != ((p + self.y) & 0xFF00)):
            self.io()
        return (((self.dbr << 16) | p) + self.y) & 0xFFFFFF, 0xFFFFFF

    def ea_indl(self):                  # [dp]
        o = self.fetch(); self.dp_base()
        pa = (self.d + o) & 0xFFFF
        p = self.r8(pa) | (self.r8((pa + 1) & 0xFFFF) << 8) | (self.r8((pa + 2) & 0xFFFF) << 16)
        return p, 0xFFFFFF

    def ea_indly(self):                 # [dp],Y
        a, _ = self.ea_indl()
        return (a + self.y) & 0xFFFFFF, 0xFFFFFF

    def ea_sr(self):                    # sr,S
        o = self.fetch(); self.io()
        return (self.s + o) & 0xFFFF, 0xFFFF

    def ea_sry(self):                   # (sr,S),Y
        o = self.fetch(); self.io()
        pa = (self.s + o) & 0xFFFF
        p = self.r8(pa) | (self.r8((pa + 1) & 0xFFFF) << 8)
        self.io()
        return (((self.dbr << 16) | p) + self.y) & 0xFFFFFF, 0xFFFFFF

    # --- operands at M / X width ---------------------------------------------------------
    def load_m(self, ea):
        a, w = ea
        return self.r8(a) if self.m8 else self.rd16(a, w)

    def store_m(self, ea, v):
        a, w = ea
        if self.m8:
            self.w8(a, v)
        else:
            self.wr16(a, v, w)

    def load_x(self, ea):
        a, w = ea
        return self.r8(a) if self.x8 else self.rd16(a, w)

    def store_x(self, ea, v):
        a, w = ea
        if self.x8:
            self.w8(a, v)
        else:
            self.wr16(a, v, w)

    def imm_m(self):
        return self.fetch() if self.m8 else self.fetch16()

    def imm_x(self):
        return self.fetch() if self.x8 else self.fetch16()

    # --- the accumulator ------------------------------------------------------------------
    @property
    def acc(self):
        return self.a & 0xFF if self.m8 else self.a

    @acc.setter
    def acc(self, v):
        if self.m8:
            self.a = (self.a & 0xFF00) | (v & 0xFF)
        else:
            self.a = v & 0xFFFF

    # --- arithmetic ---------------------------------------------------------------------------
    def adc(self, v):
        c = self.p & C
        if self.m8:
            a = self.a & 0xFF
            if self.p & D:
                lo = (a & 0x0F) + (v & 0x0F) + c
                if lo > 9: lo += 6
                r = (a & 0xF0) + (v & 0xF0) + (lo if lo < 0x10 else (lo & 0x0F) + 0x10)
                ov = (~(a ^ v) & (a ^ r) & 0x80)
                if r > 0x9F: r += 0x60
                self.p = (self.p & ~(C | V)) | (C if r > 0xFF else 0) | (V if ov else 0)
            else:
                r = a + v + c
                ov = (~(a ^ v) & (a ^ r) & 0x80)
                self.p = (self.p & ~(C | V)) | (C if r > 0xFF else 0) | (V if ov else 0)
            self.acc = r
            self.nz8(r)
        else:
            a = self.a
            if self.p & D:
                r = c
                res = 0
                for sh in (0, 4, 8, 12):
                    dsum = ((a >> sh) & 0xF) + ((v >> sh) & 0xF) + r
                    if sh == 12:
                        top_bin = dsum
                    r = 0
                    if dsum > 9:
                        dsum += 6
                    if dsum > 0xF:
                        r = 1
                        dsum &= 0xF
                    res |= dsum << sh
                # (V from the sum before the top digit's adjust, as the chip does)
                pre = (res & 0x0FFF) | ((top_bin & 0xF) << 12)
                ov = (~(a ^ v) & (a ^ pre) & 0x8000)
                self.p = (self.p & ~(C | V)) | (C if r else 0) | (V if ov else 0)
                self.a = res & 0xFFFF
            else:
                r = a + v + c
                ov = (~(a ^ v) & (a ^ r) & 0x8000)
                self.p = (self.p & ~(C | V)) | (C if r > 0xFFFF else 0) | (V if ov else 0)
                self.a = r & 0xFFFF
            self.nz16(self.a)

    def sbc(self, v):
        c = self.p & C
        if self.m8:
            a = self.a & 0xFF
            if self.p & D:
                v8 = v ^ 0xFF
                r = a + v8 + c
                ov = (~(a ^ v8) & (a ^ r) & 0x80)
                self.p = (self.p & ~(C | V)) | (C if r > 0xFF else 0) | (V if ov else 0)
                self.acc = _bcd_sub8_res(a, v, c)
            else:
                v8 = v ^ 0xFF
                r = a + v8 + c
                ov = (~(a ^ v8) & (a ^ r) & 0x80)
                self.p = (self.p & ~(C | V)) | (C if r > 0xFF else 0) | (V if ov else 0)
                self.acc = r
            self.nz8(self.acc)
        else:
            a = self.a
            v16 = v ^ 0xFFFF
            r = a + v16 + c
            ov = (~(a ^ v16) & (a ^ r) & 0x8000)
            self.p = (self.p & ~(C | V)) | (C if r > 0xFFFF else 0) | (V if ov else 0)
            if self.p & D:
                self.a = _bcd_sub16_res(a, v, c)
            else:
                self.a = r & 0xFFFF
            self.nz16(self.a)

    def cmp(self, reg, v, eight):
        if eight:
            r = (reg & 0xFF) - (v & 0xFF)
            self.p = (self.p & ~C) | (C if r >= 0 else 0)
            self.nz8(r & 0xFF)
        else:
            r = reg - v
            self.p = (self.p & ~C) | (C if r >= 0 else 0)
            self.nz16(r & 0xFFFF)

    # --- read-modify-write ------------------------------------------------------------------
    def rmw(self, ea, fn):
        a, w = ea
        if self.m8:
            v = self.r8(a); self.io()
            if self.e:
                pass
            r = fn(v, 8) & 0xFF
            self.w8(a, r)
        else:
            v = self.rd16(a, w); self.io()
            r = fn(v, 16) & 0xFFFF
            a2 = (a & ~w) | ((a + 1) & w)
            self.w8(a2, r >> 8)
            self.w8(a, r)

    def _asl(self, v, bits):
        top = 1 << (bits - 1)
        self.p = (self.p & ~C) | (C if v & top else 0)
        r = (v << 1) & ((1 << bits) - 1)
        self.nz8(r) if bits == 8 else self.nz16(r)
        return r

    def _lsr(self, v, bits):
        self.p = (self.p & ~C) | (v & 1)
        r = v >> 1
        self.nz8(r) if bits == 8 else self.nz16(r)
        return r

    def _rol(self, v, bits):
        top = 1 << (bits - 1)
        r = ((v << 1) | (self.p & C)) & ((1 << bits) - 1)
        self.p = (self.p & ~C) | (C if v & top else 0)
        self.nz8(r) if bits == 8 else self.nz16(r)
        return r

    def _ror(self, v, bits):
        r = (v >> 1) | ((self.p & C) << (bits - 1))
        self.p = (self.p & ~C) | (v & 1)
        self.nz8(r) if bits == 8 else self.nz16(r)
        return r

    def _inc(self, v, bits):
        r = (v + 1) & ((1 << bits) - 1)
        self.nz8(r) if bits == 8 else self.nz16(r)
        return r

    def _dec(self, v, bits):
        r = (v - 1) & ((1 << bits) - 1)
        self.nz8(r) if bits == 8 else self.nz16(r)
        return r

    def _tsb(self, v, bits):
        acc = self.a & ((1 << bits) - 1)
        self.p = (self.p & ~Z) | (Z if (v & acc) == 0 else 0)
        return v | acc

    def _trb(self, v, bits):
        acc = self.a & ((1 << bits) - 1)
        self.p = (self.p & ~Z) | (Z if (v & acc) == 0 else 0)
        return v & ~acc

    # --- interrupts ---------------------------------------------------------------------------
    def interrupt(self, vec_native, vec_emu, brk=False):
        if not self.e:
            self.push(self.pbr)
        self.push16(self.pc)
        self.push(self.p | (0x10 if (self.e and brk) else 0) if self.e else self.p)
        self.p = (self.p | I) & ~D
        self.pbr = 0
        vec = vec_emu if self.e else vec_native
        self.pc = self.r8(vec) | (self.r8(vec + 1) << 8)

    def irq(self):
        if self.p & I:
            return
        self.waiting = False
        self.io(); self.io()
        self.interrupt(0xFFEE, 0xFFFE)

    def nmi(self):
        self.waiting = False
        self.io(); self.io()
        self.interrupt(0xFFEA, 0xFFFA)

    # --- one instruction ---------------------------------------------------------------------
    def step(self):
        # (what the chip itself keeps true: in emulation mode S is in page 1 and M, X are set;
        # with X set the index registers' high bytes are zero)
        if self.e:
            self.s = 0x0100 | (self.s & 0xFF)
            self.p |= M | XF
        if self.p & XF:
            self.x &= 0xFF
            self.y &= 0xFF
        if self.stopped or self.waiting:
            self.io()
            return
        op = self.fetch()
        OPS[op](self)


def _bcd_sub8_res(a, v, c):
    """decimal subtract, 8 bits: the result the 65816 leaves (digit by digit, borrow in)"""
    lo = (a & 0x0F) - (v & 0x0F) - (1 - c)
    hi = (a >> 4) - (v >> 4)
    if lo < 0:
        lo -= 6
        hi -= 1
    if hi < 0:
        hi -= 6
    return ((hi << 4) | (lo & 0x0F)) & 0xFF


def _bcd_sub16_res(a, v, c):
    res = 0
    borrow = 1 - c
    for sh in (0, 4, 8, 12):
        d = ((a >> sh) & 0xF) - ((v >> sh) & 0xF) - borrow
        borrow = 0
        if d < 0:
            d -= 6
            borrow = 1
        res |= (d & 0xF) << sh
    return res & 0xFFFF


# =============================================================================================
# the opcode table
# =============================================================================================
OPS = [None] * 256

# the addressing modes of the eight-group ALU ops (ORA AND EOR ADC STA LDA CMP SBC):
# low 5 bits of the opcode -> how the operand is reached
def _mode(c, m, write=False):
    return {
        0x01: c.ea_indx, 0x03: c.ea_sr, 0x05: c.ea_dp, 0x07: c.ea_indl,
        0x0D: c.ea_abs, 0x0F: c.ea_long,
        0x11: lambda: c.ea_indy(write), 0x12: c.ea_ind, 0x13: c.ea_sry,
        0x15: lambda: c.ea_dpx(c.x), 0x17: c.ea_indly,
        0x19: lambda: c.ea_absx(c.y, write), 0x1D: lambda: c.ea_absx(c.x, write), 0x1F: c.ea_longx,
    }[m]()


def _alu(group):
    def op(c, m):
        if m == 0x09:
            v = c.imm_m()
        else:
            v = c.load_m(_mode(c, m))
        if group == 0:
            c.acc = c.acc | v; c.nzm(c.acc)
        elif group == 1:
            c.acc = c.acc & v; c.nzm(c.acc)
        elif group == 2:
            c.acc = c.acc ^ v; c.nzm(c.acc)
        elif group == 3:
            c.adc(v)
        elif group == 5:
            c.acc = v; c.nzm(v)
        elif group == 6:
            c.cmp(c.a, v, c.m8)
        elif group == 7:
            c.sbc(v)
    return op


for g in range(8):
    for m in (0x01, 0x03, 0x05, 0x07, 0x09, 0x0D, 0x0F, 0x11, 0x12, 0x13, 0x15, 0x17, 0x19, 0x1D, 0x1F):
        code = (g << 5) | m
        if g == 4:
            if m == 0x09:
                continue                    # (0x89 is BIT #imm)
            OPS[code] = (lambda mm: lambda c: c.store_m(_mode(c, mm, True), c.acc))(m)
        else:
            OPS[code] = (lambda f, mm: lambda c: f(c, mm))(_alu(g), m)


def _def(code):
    def reg(fn):
        OPS[code] = fn
        return fn
    return reg


# --- read-modify-write: ASL ROL LSR ROR (accumulator and memory), INC DEC, TSB TRB --------------
def _rmw_ops(base, fname):
    def acc(c):
        c.io()
        f = getattr(c, fname)
        c.acc = f(c.acc, 8 if c.m8 else 16)
    OPS[base | 0x0A] = acc
    OPS[base | 0x06] = lambda c: c.rmw(c.ea_dp(), getattr(c, fname))
    OPS[base | 0x0E] = lambda c: c.rmw(c.ea_abs(), getattr(c, fname))
    OPS[base | 0x16] = lambda c: c.rmw(c.ea_dpx(c.x), getattr(c, fname))
    OPS[base | 0x1E] = lambda c: c.rmw(c.ea_absx(c.x, True), getattr(c, fname))


_rmw_ops(0x00, '_asl'); _rmw_ops(0x20, '_rol'); _rmw_ops(0x40, '_lsr'); _rmw_ops(0x60, '_ror')
OPS[0x1A] = lambda c: (c.io(), setattr(c, 'acc', c._inc(c.acc, 8 if c.m8 else 16)))   # INC A
OPS[0x3A] = lambda c: (c.io(), setattr(c, 'acc', c._dec(c.acc, 8 if c.m8 else 16)))   # DEC A
OPS[0xE6] = lambda c: c.rmw(c.ea_dp(), c._inc)
OPS[0xEE] = lambda c: c.rmw(c.ea_abs(), c._inc)
OPS[0xF6] = lambda c: c.rmw(c.ea_dpx(c.x), c._inc)
OPS[0xFE] = lambda c: c.rmw(c.ea_absx(c.x, True), c._inc)
OPS[0xC6] = lambda c: c.rmw(c.ea_dp(), c._dec)
OPS[0xCE] = lambda c: c.rmw(c.ea_abs(), c._dec)
OPS[0xD6] = lambda c: c.rmw(c.ea_dpx(c.x), c._dec)
OPS[0xDE] = lambda c: c.rmw(c.ea_absx(c.x, True), c._dec)
OPS[0x04] = lambda c: c.rmw(c.ea_dp(), c._tsb)
OPS[0x0C] = lambda c: c.rmw(c.ea_abs(), c._tsb)
OPS[0x14] = lambda c: c.rmw(c.ea_dp(), c._trb)
OPS[0x1C] = lambda c: c.rmw(c.ea_abs(), c._trb)


# --- BIT ------------------------------------------------------------------------------------
def _bit(c, v, imm=False):
    acc = c.acc
    c.p = (c.p & ~Z) | (Z if (acc & v) == 0 else 0)
    if not imm:
        top = 0x80 if c.m8 else 0x8000
        c.p = (c.p & ~(N | V)) | (N if v & top else 0) | (V if v & (top >> 1) else 0)


OPS[0x89] = lambda c: _bit(c, c.imm_m(), True)
OPS[0x24] = lambda c: _bit(c, c.load_m(c.ea_dp()))
OPS[0x2C] = lambda c: _bit(c, c.load_m(c.ea_abs()))
OPS[0x34] = lambda c: _bit(c, c.load_m(c.ea_dpx(c.x)))
OPS[0x3C] = lambda c: _bit(c, c.load_m(c.ea_absx(c.x)))


# --- the index registers: LDX LDY STX STY CPX CPY, STZ ------------------------------------------
def _ldx(c, v): c.x = v; c.nzx(v)
def _ldy(c, v): c.y = v; c.nzx(v)


OPS[0xA2] = lambda c: _ldx(c, c.imm_x())
OPS[0xA6] = lambda c: _ldx(c, c.load_x(c.ea_dp()))
OPS[0xAE] = lambda c: _ldx(c, c.load_x(c.ea_abs()))
OPS[0xB6] = lambda c: _ldx(c, c.load_x(c.ea_dpx(c.y)))
OPS[0xBE] = lambda c: _ldx(c, c.load_x(c.ea_absx(c.y)))
OPS[0xA0] = lambda c: _ldy(c, c.imm_x())
OPS[0xA4] = lambda c: _ldy(c, c.load_x(c.ea_dp()))
OPS[0xAC] = lambda c: _ldy(c, c.load_x(c.ea_abs()))
OPS[0xB4] = lambda c: _ldy(c, c.load_x(c.ea_dpx(c.x)))
OPS[0xBC] = lambda c: _ldy(c, c.load_x(c.ea_absx(c.x)))
OPS[0x86] = lambda c: c.store_x(c.ea_dp(), c.x)
OPS[0x8E] = lambda c: c.store_x(c.ea_abs(), c.x)
OPS[0x96] = lambda c: c.store_x(c.ea_dpx(c.y), c.x)
OPS[0x84] = lambda c: c.store_x(c.ea_dp(), c.y)
OPS[0x8C] = lambda c: c.store_x(c.ea_abs(), c.y)
OPS[0x94] = lambda c: c.store_x(c.ea_dpx(c.x), c.y)
OPS[0xE0] = lambda c: c.cmp(c.x, c.imm_x(), c.x8)
OPS[0xE4] = lambda c: c.cmp(c.x, c.load_x(c.ea_dp()), c.x8)
OPS[0xEC] = lambda c: c.cmp(c.x, c.load_x(c.ea_abs()), c.x8)
OPS[0xC0] = lambda c: c.cmp(c.y, c.imm_x(), c.x8)
OPS[0xC4] = lambda c: c.cmp(c.y, c.load_x(c.ea_dp()), c.x8)
OPS[0xCC] = lambda c: c.cmp(c.y, c.load_x(c.ea_abs()), c.x8)
OPS[0x64] = lambda c: c.store_m(c.ea_dp(), 0)
OPS[0x74] = lambda c: c.store_m(c.ea_dpx(c.x), 0)
OPS[0x9C] = lambda c: c.store_m(c.ea_abs(), 0)
OPS[0x9E] = lambda c: c.store_m(c.ea_absx(c.x, True), 0)


# --- register to register ----------------------------------------------------------------
def _xfer_m(c, v): c.io(); c.acc = v; c.nzm(c.acc)
def _xfer_x(c, attr, v):
    c.io()
    v &= 0xFF if c.x8 else 0xFFFF
    setattr(c, attr, v); c.nzx(v)


OPS[0xAA] = lambda c: _xfer_x(c, 'x', c.a)              # TAX
OPS[0xA8] = lambda c: _xfer_x(c, 'y', c.a)              # TAY
OPS[0x8A] = lambda c: _xfer_m(c, c.x)                   # TXA
OPS[0x98] = lambda c: _xfer_m(c, c.y)                   # TYA
OPS[0x9B] = lambda c: _xfer_x(c, 'y', c.x)              # TXY
OPS[0xBB] = lambda c: _xfer_x(c, 'x', c.y)              # TYX
OPS[0xBA] = lambda c: _xfer_x(c, 'x', c.s)              # TSX


def _txs(c):
    c.io()
    c.s = (0x0100 | (c.x & 0xFF)) if c.e else c.x


OPS[0x9A] = _txs


def _tcs(c):
    c.io()
    c.s = (0x0100 | (c.a & 0xFF)) if c.e else c.a


OPS[0x1B] = _tcs
OPS[0x3B] = lambda c: (c.io(), setattr(c, 'a', c.s), c.nz16(c.s))          # TSC
OPS[0x5B] = lambda c: (c.io(), setattr(c, 'd', c.a), c.nz16(c.a))          # TCD
OPS[0x7B] = lambda c: (c.io(), setattr(c, 'a', c.d), c.nz16(c.d))          # TDC


def _xba(c):
    c.io(); c.io()
    c.a = ((c.a >> 8) | (c.a << 8)) & 0xFFFF
    c.nz8(c.a & 0xFF)


OPS[0xEB] = _xba


def _inxy(attr, d):
    def f(c):
        c.io()
        v = (getattr(c, attr) + d) & (0xFF if c.x8 else 0xFFFF)
        setattr(c, attr, v); c.nzx(v)
    return f


OPS[0xE8] = _inxy('x', 1); OPS[0xC8] = _inxy('y', 1)
OPS[0xCA] = _inxy('x', -1); OPS[0x88] = _inxy('y', -1)


# --- flags ----------------------------------------------------------------------------------
def _flag(mask, on):
    def f(c):
        c.io()
        c.p = (c.p | mask) if on else (c.p & ~mask)
    return f


OPS[0x18] = _flag(C, 0); OPS[0x38] = _flag(C, 1); OPS[0x58] = _flag(I, 0); OPS[0x78] = _flag(I, 1)
OPS[0xB8] = _flag(V, 0); OPS[0xD8] = _flag(D, 0); OPS[0xF8] = _flag(D, 1)


def _rep(c):
    v = c.fetch(); c.io()
    c.setp(c.p & ~v)


def _sep(c):
    v = c.fetch(); c.io()
    c.setp(c.p | v)


OPS[0xC2] = _rep; OPS[0xE2] = _sep


def _xce(c):
    c.io()
    carry = c.p & C
    c.p = (c.p & ~C) | c.e
    c.e = carry
    if c.e:
        c.setp(c.p | M | XF)
        c.s = 0x0100 | (c.s & 0xFF)


OPS[0xFB] = _xce


# --- branches ---------------------------------------------------------------------------------
def _branch(cond):
    def f(c):
        off = c.fetch()
        if cond(c):
            off = off - 256 if off & 0x80 else off
            c.io()
            new = (c.pc + off) & 0xFFFF
            if c.e and (new & 0xFF00) != (c.pc & 0xFF00):
                c.io()
            c.pc = new
    return f


OPS[0x10] = _branch(lambda c: not c.p & N); OPS[0x30] = _branch(lambda c: c.p & N)
OPS[0x50] = _branch(lambda c: not c.p & V); OPS[0x70] = _branch(lambda c: c.p & V)
OPS[0x90] = _branch(lambda c: not c.p & C); OPS[0xB0] = _branch(lambda c: c.p & C)
OPS[0xD0] = _branch(lambda c: not c.p & Z); OPS[0xF0] = _branch(lambda c: c.p & Z)
OPS[0x80] = _branch(lambda c: True)


def _brl(c):
    off = c.fetch16(); c.io()
    c.pc = (c.pc + off) & 0xFFFF


OPS[0x82] = _brl


# --- jumps and calls ------------------------------------------------------------------------
def _jmp_abs(c): c.pc = c.fetch16()
def _jml(c):
    a = c.fetch24(); c.pc = a & 0xFFFF; c.pbr = a >> 16
def _jmp_ind(c):
    p = c.fetch16()
    c.pc = c.r8(p) | (c.r8((p + 1) & 0xFFFF) << 8)
def _jmp_indx(c):
    p = c.fetch16(); c.io()
    a = (c.pbr << 16) | ((p + c.x) & 0xFFFF)
    c.pc = c.r8(a) | (c.r8((c.pbr << 16) | ((p + c.x + 1) & 0xFFFF)) << 8)
def _jml_ind(c):
    p = c.fetch16()
    c.pc = c.r8(p) | (c.r8((p + 1) & 0xFFFF) << 8)
    c.pbr = c.r8((p + 2) & 0xFFFF)


OPS[0x4C] = _jmp_abs; OPS[0x5C] = _jml; OPS[0x6C] = _jmp_ind; OPS[0x7C] = _jmp_indx; OPS[0xDC] = _jml_ind


def _jsr(c):
    t = c.fetch16(); c.io()
    c.push16((c.pc - 1) & 0xFFFF)
    c.pc = t


def _jsl(c):
    lo = c.fetch16()
    c.push(c.pbr, True)
    c.io()
    bank = c.fetch()
    c.push16((c.pc - 1) & 0xFFFF, True)
    c.pc = lo; c.pbr = bank
    c.fix_s()


def _jsr_indx(c):
    lo = c.fetch()
    c.push16(c.pc, True)                 # (leaves page 1 like the other new ones: gilyon
                                         # test 0277, from hardware; SingleStepTests wraps it)
    hi = c.fetch()
    p = (lo | (hi << 8))
    c.io()
    a = (c.pbr << 16) | ((p + c.x) & 0xFFFF)
    c.pc = c.r8(a) | (c.r8((c.pbr << 16) | ((p + c.x + 1) & 0xFFFF)) << 8)
    c.fix_s()


def _rts(c):
    c.io(); c.io()
    c.pc = (c.pull16() + 1) & 0xFFFF
    c.io()


def _rtl(c):
    c.io(); c.io()
    c.pc = (c.pull16(True) + 1) & 0xFFFF
    c.pbr = c.pull(True)
    c.fix_s()


def _rti(c):
    c.io(); c.io()
    c.setp(c.pull())
    c.pc = c.pull16()
    if not c.e:
        c.pbr = c.pull()


OPS[0x20] = _jsr; OPS[0x22] = _jsl; OPS[0xFC] = _jsr_indx
OPS[0x60] = _rts; OPS[0x6B] = _rtl; OPS[0x40] = _rti


def _brk(c):
    c.fetch()
    c.interrupt(0xFFE6, 0xFFFE, True)


def _cop(c):
    c.fetch()
    c.interrupt(0xFFE4, 0xFFF4)


OPS[0x00] = _brk; OPS[0x02] = _cop


# --- the stack --------------------------------------------------------------------------------
def _pha(c):
    c.io()
    if c.m8: c.push(c.a & 0xFF)
    else: c.push16(c.a)


def _pla(c):
    c.io(); c.io()
    v = c.pull() if c.m8 else c.pull16()
    c.acc = v; c.nzm(v)


def _phxy(attr):
    def f(c):
        c.io()
        v = getattr(c, attr)
        if c.x8: c.push(v & 0xFF)
        else: c.push16(v)
    return f


def _plxy(attr):
    def f(c):
        c.io(); c.io()
        v = c.pull() if c.x8 else c.pull16()
        setattr(c, attr, v); c.nzx(v)
    return f


OPS[0x48] = _pha; OPS[0x68] = _pla
OPS[0xDA] = _phxy('x'); OPS[0x5A] = _phxy('y'); OPS[0xFA] = _plxy('x'); OPS[0x7A] = _plxy('y')
OPS[0x08] = lambda c: (c.io(), c.push(c.p))                                   # PHP
OPS[0x28] = lambda c: (c.io(), c.io(), c.setp(c.pull()))                      # PLP
OPS[0x8B] = lambda c: (c.io(), c.push(c.dbr))                                  # PHB
OPS[0x4B] = lambda c: (c.io(), c.push(c.pbr))                                  # PHK


def _plb(c):
    c.io(); c.io()
    c.dbr = c.pull(True); c.nz8(c.dbr); c.fix_s()


def _phd(c):
    c.io(); c.push16(c.d, True); c.fix_s()


def _pld(c):
    c.io(); c.io()
    c.d = c.pull16(True); c.nz16(c.d); c.fix_s()


def _pea(c):
    v = c.fetch16(); c.push16(v, True); c.fix_s()


def _pei(c):
    o = c.fetch(); c.dp_base()
    pa = (c.d + o) & 0xFFFF
    v = c.r8(pa) | (c.r8((pa + 1) & 0xFFFF) << 8)
    c.push16(v, True); c.fix_s()


def _per(c):
    off = c.fetch16(); c.io()
    c.push16((c.pc + off) & 0xFFFF, True); c.fix_s()


OPS[0xAB] = _plb; OPS[0x0B] = _phd; OPS[0x2B] = _pld
OPS[0xF4] = _pea; OPS[0xD4] = _pei; OPS[0x62] = _per


# --- block moves --------------------------------------------------------------------------
def _mv(step):
    def f(c):
        dst = c.fetch(); src = c.fetch()
        c.dbr = dst
        v = c.r8((src << 16) | c.x)
        c.w8((dst << 16) | c.y, v)
        c.io(); c.io()
        mask = 0xFF if c.x8 else 0xFFFF
        c.x = (c.x + step) & mask
        c.y = (c.y + step) & mask
        c.a = (c.a - 1) & 0xFFFF
        if c.a != 0xFFFF:
            c.pc = (c.pc - 3) & 0xFFFF            # the instruction again
    return f


OPS[0x54] = _mv(1)      # MVN
OPS[0x44] = _mv(-1)     # MVP


# --- the rest -------------------------------------------------------------------------------
OPS[0xEA] = lambda c: c.io()                                  # NOP
OPS[0x42] = lambda c: c.fetch()                               # WDM
OPS[0xCB] = lambda c: (c.io(), c.io(), c.io(), setattr(c, 'waiting', True))   # WAI
OPS[0xDB] = lambda c: (c.io(), c.io(), c.io(), setattr(c, 'stopped', True))   # STP

missing = [hex(i) for i, f in enumerate(OPS) if f is None]
assert not missing, missing
