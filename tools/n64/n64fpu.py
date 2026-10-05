"""The VR4300's floating-point unit (COP1), for tools/n64/n64model.py.

Behaviour follows ares (ares/n64/cpu/interpreter-fpu.cpp, ISC), which runs
the host's IEEE arithmetic and reads its exception flags. The host's floats are
not used here: every result is worked out exactly as a fraction and rounded to
the format in the rounding mode FCR31 selects, so all four modes and every flag
come out the same on any machine. Where ares depends on the x86 it runs on,
this does what x86 does: tininess is detected after rounding, and underflow is
flagged only when the result is also inexact (the masked-exception rule).

What the VR4300 itself does, and ares with it:
- A subnormal input or result, or a "quiet" NaN input (quiet bit CLEAR: the
  old MIPS convention), is not handled by the hardware: the Unimplemented
  Operation cause is set and the instruction traps, so software can emulate it.
  A subnormal result is flushed instead when FCR31.FS is set and neither the
  underflow nor the inexact exception is enabled.
- A signalling NaN (quiet bit SET) is an invalid operation; untrapped, the
  result is the default NaN 7FBFFFFF / 7FF7FFFFFFFFFFFF.
- Conversions to integer trap as unimplemented for NaN, infinity, subnormal,
  or a value out of range (W: outside [-2^31, 2^31); L: |x| >= 2^53).
- With Status.FR clear, the even/odd register pairs alias as ares models them
  (fgr_t / fgr_s / fgr_d below), including the asymmetric corners.
"""
from fractions import Fraction

M32 = 0xFFFFFFFF
M64 = (1 << 64) - 1

# FCR31 fields: flags 2..6, enables 7..11, cause 12..17, in the order I U O Z V (E)
I, U, O, Z, V, E = 0, 1, 2, 3, 4, 5


class Fmt:
    def __init__(self, ebits, p):
        self.ebits, self.p = ebits, p          # p: significand bits with the hidden one
        self.bias = (1 << (ebits - 1)) - 1
        self.emin = 1 - self.bias
        self.emax = self.bias
        self.width = ebits + p
        self.mmask = (1 << (p - 1)) - 1
        self.emask = (1 << ebits) - 1
        self.qbit = 1 << (p - 2)                # set: a SIGNALLING NaN on the VR4300
        self.default_nan = (self.emask << (p - 1)) | (self.mmask & ~self.qbit)


S = Fmt(8, 24)
D = Fmt(11, 53)


class Trap(Exception):
    """the instruction traps: a floating-point exception (or unusable coprocessor)"""


class Value:
    __slots__ = ('kind', 'sign', 'mag', 'bits', 'snan')

    def __init__(self, bits, f):
        self.bits = bits
        self.sign = bits >> (f.width - 1) & 1
        e = bits >> (f.p - 1) & f.emask
        m = bits & f.mmask
        self.snan = False
        if e == f.emask:
            self.kind = 'nan' if m else 'inf'
            self.snan = bool(m & f.qbit)
            self.mag = None
        elif e == 0:
            self.kind = 'sub' if m else 'zero'
            self.mag = Fraction(m, 1 << (f.p - 1 - f.emin))
        else:
            self.kind = 'norm'
            self.mag = Fraction(m | (1 << (f.p - 1))) * Fraction(2) ** (e - f.bias - f.p + 1)

    def value(self):
        return -self.mag if self.sign else self.mag

    def is_nan(self):
        return self.kind == 'nan'


def _floor_log2(x):
    """the e with 2^e <= x < 2^(e+1), x a positive Fraction"""
    e = x.numerator.bit_length() - x.denominator.bit_length()
    if x < Fraction(2) ** e:
        e -= 1
    elif x >= Fraction(2) ** (e + 1):
        e += 1
    return e


def _round_int(q, sign, mode):
    """q >= 0 rounded to an integer by the mode (0 RN, 1 RZ, 2 RP, 3 RM)"""
    n = q.numerator // q.denominator
    rem = q - n
    if rem:
        if mode == 0:
            if rem > Fraction(1, 2) or (rem == Fraction(1, 2) and n & 1):
                n += 1
        elif mode == 2 and not sign:
            n += 1
        elif mode == 3 and sign:
            n += 1
    return n, rem != 0


def round_to(f, x, mode, zero_sign=0):
    """the exact value x rounded into format f: (bits, set of flags)"""
    if x == 0:
        return zero_sign << (f.width - 1), set()
    sign = 1 if x < 0 else 0
    a = -x if sign else x
    flags = set()
    e = max(_floor_log2(a), f.emin)
    quantum = Fraction(2) ** (e - f.p + 1)
    n, inexact = _round_int(a / quantum, sign, mode)
    r = n * quantum
    # tininess after rounding, as x86 detects it: the result rounded with an
    # unbounded exponent is below the smallest normal
    if inexact:
        flags.add(I)
        eu = _floor_log2(a)
        nu, _ = _round_int(a / Fraction(2) ** (eu - f.p + 1), sign, mode)
        if nu * Fraction(2) ** (eu - f.p + 1) < Fraction(2) ** f.emin:
            flags.add(U)
    if r >= Fraction(2) ** (f.emax + 1):
        flags |= {O, I}
        to_inf = mode == 0 or (mode == 2 and not sign) or (mode == 3 and sign)
        if to_inf:
            return (sign << (f.width - 1)) | (f.emask << (f.p - 1)), flags
        return (sign << (f.width - 1)) | ((f.emask - 1) << (f.p - 1)) | f.mmask, flags
    if r == 0:
        return sign << (f.width - 1), flags
    if r < Fraction(2) ** f.emin:
        m = r / Fraction(2) ** (f.emin - f.p + 1)
        return (sign << (f.width - 1)) | int(m), flags
    er = _floor_log2(r)
    m = int(r / Fraction(2) ** (er - f.p + 1)) - (1 << (f.p - 1))
    return (sign << (f.width - 1)) | ((er + f.bias) << (f.p - 1)) | m, flags


def _sqrt_exact(x, p):
    """sqrt(x) for a positive dyadic x, exact or nudged by half a unit so that
    rounding it to p bits rounds the true root correctly"""
    k = 0
    while True:
        # x * 4^k as an integer with enough bits for p + 2 bits of root
        n4 = x * Fraction(4) ** k
        if n4.denominator == 1 and n4.numerator.bit_length() >= 2 * (p + 3):
            break
        k += 1
    n = n4.numerator
    import math
    r = math.isqrt(n)
    root = Fraction(r) if r * r == n else Fraction(2 * r + 1, 2)
    return root / Fraction(2) ** k


def _bits_float(bits, f):
    """the value as a Python float, for comparisons (exact: doubles hold both formats)"""
    import struct
    if f is S:
        return struct.unpack('>f', struct.pack('>I', bits & M32))[0]
    return struct.unpack('>d', struct.pack('>Q', bits & M64))[0]


class FPU:
    def __init__(self, cpu):
        self.cpu = cpu
        self.r = [0] * 32
        self.fcr31 = 0

    # --- FCR31 ---------------------------------------------------------------------
    def cause_reset(self):
        self.fcr31 &= ~(0x3F << 12)

    def enabled(self, b):
        return self.fcr31 >> (7 + b) & 1

    def raise_(self, b):
        """an exception condition: the cause bit, and the flag unless trapping.
        True when it traps."""
        self.fcr31 |= 1 << (12 + b)
        if b == E:
            return True
        if self.enabled(b):
            return True
        self.fcr31 |= 1 << (2 + b)
        return False

    def trap(self):
        raise Trap()

    @property
    def mode(self):
        return self.fcr31 & 3

    @property
    def flush(self):
        return self.fcr31 >> 24 & 1

    # --- registers (ares fgr_t / fgr_s / fgr_d) -------------------------------------
    def fr(self):
        return self.cpu.status >> 26 & 1

    def t32(self, i):
        if self.fr():
            return self.r[i] & M32
        if i & 1:
            return self.r[i & ~1] >> 32
        return self.r[i] & M32

    def set_t32(self, i, v):
        v &= M32
        if self.fr():
            self.r[i] = (self.r[i] & ~M32) | v
        elif i & 1:
            self.r[i & ~1] = (self.r[i & ~1] & M32) | (v << 32)
        else:
            self.r[i] = (self.r[i] & ~M32) | v

    def s32(self, i):                      # fgr_s<s32>, fgr_s<f32>
        return self.r[i if self.fr() else i & ~1] & M32

    def t64(self, i):                      # fgr_t<s64>, fgr_s<s64>, fgr_s<f64>
        return self.r[i if self.fr() else i & ~1]

    def set_t64(self, i, v):
        self.r[i if self.fr() else i & ~1] = v & M64

    def d32(self, i, v):                   # fgr_d<s32>, fgr_d<f32>: the upper half cleared
        self.r[i] = v & M32

    def d64(self, i, v):
        self.r[i] = v & M64

    def tf32(self, i):                     # fgr_t<f32>: no pairing
        return self.r[i] & M32

    def tf64(self, i):                     # fgr_t<f64>
        return self.r[i]

    # --- the checks ---------------------------------------------------------------
    def check_start(self):
        if not (self.cpu.status >> 29 & 1):
            raise CopUnusable()
        self.cause_reset()

    def check_input(self, v):
        if v.kind == 'sub':
            self.raise_(E); self.trap()
        if v.kind == 'nan':
            if self.raise_(V) if v.snan else self.raise_(E):
                self.trap()

    def check_inputs(self, a, b):
        if (a.is_nan() and not a.snan) or (b.is_nan() and not b.snan):
            self.raise_(E); self.trap()
        if a.kind == 'sub' or b.kind == 'sub':
            self.raise_(E); self.trap()
        if (a.is_nan() and a.snan) or (b.is_nan() and b.snan):
            if self.raise_(V):
                self.trap()

    def check_conv(self, v, f, lim64):
        if v.kind in ('sub', 'inf', 'nan'):
            self.raise_(E); self.trap()
        x = v.value()
        if lim64:
            if x >= 2 ** 53 or x <= -2 ** 53:
                self.raise_(E); self.trap()
        elif x >= 2 ** 31 or x < -2 ** 31:
            self.raise_(E); self.trap()

    def finish(self, f, flags, bits, conv=False):
        """checkFPUExceptions, then fpuCheckOutput: the result's bits, or a trap"""
        if conv and V in flags:
            self.raise_(E); self.trap()
        if U in flags:
            if not self.flush or self.enabled(U) or self.enabled(I):
                self.raise_(E); self.trap()
        trap = False
        for b in (Z, I, U, O, V):
            if b in flags:
                trap |= self.raise_(b)
        if trap:
            self.trap()
        if f is None:
            return bits
        e = bits >> (f.p - 1) & f.emask
        m = bits & f.mmask
        if e == 0 and m:                       # a subnormal result
            if not self.flush or self.enabled(U) or self.enabled(I):
                self.raise_(E); self.trap()
            self.raise_(U); self.raise_(I)
            sign = bits >> (f.width - 1) & 1
            mode = self.mode
            if mode == 2 and not sign:
                return 1 << (f.p - 1)          # the smallest normal
            if mode == 3 and sign:
                return (1 << (f.width - 1)) | (1 << (f.p - 1))
            return sign << (f.width - 1)
        if e == f.emask and m:
            return f.default_nan
        return bits

    # --- arithmetic ------------------------------------------------------------------
    def arith(self, f, op, a, b):
        """exact arithmetic on two checked inputs: (bits, flags)"""
        if a.is_nan() or (b is not None and b.is_nan()):
            return f.default_nan, set()
        sa, sb = a.sign, (b.sign if b is not None else 0)
        if op in ('add', 'sub'):
            if op == 'sub':
                sb ^= 1
            if a.kind == 'inf' or b.kind == 'inf':
                if a.kind == 'inf' and b.kind == 'inf' and sa != sb:
                    return f.default_nan, {V}
                s = sa if a.kind == 'inf' else sb
                return (s << (f.width - 1)) | (f.emask << (f.p - 1)), set()
            x = (-a.mag if sa else a.mag) + (-b.mag if sb else b.mag)
            if x == 0:
                if a.kind == 'zero' and b.kind == 'zero' and sa == sb:
                    zs = sa
                else:
                    zs = 1 if self.mode == 3 else 0
                return round_to(f, x, self.mode, zs)
            return round_to(f, x, self.mode)
        if op == 'mul':
            s = sa ^ sb
            if a.kind == 'inf' or b.kind == 'inf':
                if a.kind == 'zero' or b.kind == 'zero':
                    return f.default_nan, {V}
                return (s << (f.width - 1)) | (f.emask << (f.p - 1)), set()
            return round_to(f, (a.mag * b.mag) * (-1 if s else 1), self.mode, s)
        if op == 'div':
            s = sa ^ sb
            if a.kind == 'inf':
                if b.kind == 'inf':
                    return f.default_nan, {V}
                return (s << (f.width - 1)) | (f.emask << (f.p - 1)), set()
            if b.kind == 'inf':
                return s << (f.width - 1), set()
            if b.kind == 'zero':
                if a.kind == 'zero':
                    return f.default_nan, {V}
                return (s << (f.width - 1)) | (f.emask << (f.p - 1)), {Z}
            return round_to(f, (a.mag / b.mag) * (-1 if s else 1), self.mode, s)
        if op == 'sqrt':
            if a.kind == 'zero':
                return a.bits, set()
            if sa:
                return f.default_nan, {V}
            if a.kind == 'inf':
                return a.bits, set()
            return round_to(f, _sqrt_exact(a.mag, f.p), self.mode)
        raise ValueError(op)

    def to_int(self, v, how):
        """v (a checked, finite value) rounded to an integer: (n, inexact)"""
        x = v.value()
        mode = {'round': 0, 'trunc': 1, 'ceil': 2, 'floor': 3, 'cur': self.mode}[how]
        n, inexact = _round_int(abs(x), 1 if x < 0 else 0, mode)
        return (-n if x < 0 else n), inexact

    # --- the instructions ----------------------------------------------------------
    def execute(self, w, pc, tgt):
        cpu = self.cpu
        op = w >> 26
        rs = (w >> 21) & 31
        rt = (w >> 16) & 31
        fs = (w >> 11) & 31
        fd = (w >> 6) & 31
        ft = rt
        fn = w & 0x3F
        r = cpu.r

        if op != 0x11:                                            # LWC1 LDC1 SWC1 SDC1
            if not (cpu.status >> 29 & 1):
                raise CopUnusable()
            base = (r[rs] + ((w & 0xFFFF) ^ 0x8000) - 0x8000) & M64
            if op == 0x31: self.set_t32(ft, cpu.load(base, 4))
            elif op == 0x35: self.set_t64(ft, cpu.load(base, 8))
            elif op == 0x39: cpu.store(base, 4, self.t32(ft))
            else: cpu.store(base, 8, self.t64(ft))
            return

        def sx32(v):
            v &= M32
            return (v | ~M32) & M64 if v >> 31 else v

        if rs < 8 and rs not in (3, 7):
            if not (cpu.status >> 29 & 1):
                raise CopUnusable()
            if rs == 0: r[rt] = sx32(self.t32(fs))
            elif rs == 1: r[rt] = self.t64(fs)
            elif rs == 2:
                v = 0x0A00 if fs == 0 else (self.fcr31 & 0x0183FFFF if fs == 31 else 0)
                r[rt] = sx32(v)
            elif rs == 4: self.set_t32(fs, r[rt])
            elif rs == 5: self.set_t64(fs, r[rt])
            elif rs == 6:
                if fs == 31:
                    self.fcr31 = r[rt] & 0x0183FFFF
                    c = self.fcr31 >> 12 & 0x3F
                    en = self.fcr31 >> 7 & 0x1F
                    if (c & en & 0x1F) or (c & 0x20):
                        self.trap()
            return

        if rs in (16, 17) and fn == 6:                            # MOV: no checks, no cause reset
            if not (cpu.status >> 29 & 1):
                raise CopUnusable()
            self.d64(fd, self.t64(fs))
            return
        self.check_start()
        if rs == 8:                                               # BC1F BC1T BC1FL BC1TL
            if rt >= 4:
                self.raise_(E); self.trap()
            cond = (self.fcr31 >> 23 & 1) == (rt & 1)
            if cond: cpu.branch(pc, tgt)
            elif rt & 2: cpu.skip()
            else: cpu.no_branch()
            return
        if rs in (16, 17):
            f = S if rs == 16 else D
            if f is S:
                vs, vt = Value(self.s32(fs), S), Value(self.tf32(ft), S)
            else:
                vs, vt = Value(self.t64(fs), D), Value(self.tf64(ft), D)
            store = self.d32 if f is S else self.d64
            if fn in (0, 1, 2, 3):
                self.check_inputs(vs, vt)
                bits, flags = self.arith(f, ('add', 'sub', 'mul', 'div')[fn], vs, vt)
                store(fd, self.finish(f, flags, bits))
                return
            if fn == 4:
                self.check_input(vs)
                bits, flags = self.arith(f, 'sqrt', vs, None)
                store(fd, self.finish(f, flags, bits))
                return
            if fn in (5, 7):                                      # ABS NEG
                self.check_input(vs)
                if vs.is_nan():
                    bits = f.default_nan
                else:
                    sbit = 1 << (f.width - 1)
                    bits = (vs.bits & ~sbit) if fn == 5 else (vs.bits ^ sbit)
                store(fd, self.finish(f, set(), bits))
                return
            if 0x08 <= fn <= 0x0F or fn in (0x24, 0x25):          # to an integer
                lim64 = fn in (0x08, 0x09, 0x0A, 0x0B, 0x25)
                how = {0: 'round', 1: 'trunc', 2: 'ceil', 3: 'floor'}[fn & 3] if fn < 0x20 else 'cur'
                self.check_conv(vs, f, lim64)
                n, inexact = self.to_int(vs, how)
                flags = {I} if inexact else set()
                if not lim64 and not (-2 ** 31 <= n < 2 ** 31):
                    flags.add(V)                                  # rounded out of range
                self.finish(None, flags, 0, conv=not lim64)
                if lim64: self.d64(fd, n)
                else: self.d32(fd, n)
                return
            if fn == 0x20 or fn == 0x21:                          # CVT.S / CVT.D
                to = S if fn == 0x20 else D
                if to is f:
                    self.raise_(E); self.trap()
                self.check_input(vs)
                if vs.is_nan():
                    bits, flags = to.default_nan, set()
                elif vs.kind == 'inf':
                    bits, flags = (vs.sign << (to.width - 1)) | (to.emask << (to.p - 1)), set()
                else:
                    bits, flags = round_to(to, vs.value(), self.mode, vs.sign)
                (self.d32 if to is S else self.d64)(fd, self.finish(to, flags, bits))
                return
            if fn >= 0x30:                                        # C.cond
                quiet_ok = (fn & 8) == 0                            # the first eight: only sNaN signals
                if vs.is_nan() or vt.is_nan():
                    for v in (vs, vt):
                        if v.is_nan() and (not quiet_ok or v.snan) and self.raise_(V):
                            self.trap()
                    res = fn & 1                                  # the unordered bit
                else:
                    x, y = _bits_float(vs.bits, f), _bits_float(vt.bits, f)
                    res = ((fn & 4) and x < y) or ((fn & 2) and x == y)
                    res = 1 if res else 0
                self.fcr31 = (self.fcr31 & ~(1 << 23)) | (res << 23)
                return
            self.raise_(E); self.trap()
        if rs in (20, 21):                                        # from W or L
            if fn in (0x20, 0x21):
                to = S if fn == 0x20 else D
                if rs == 20:
                    n = self.s32(fs)
                    n = n - (1 << 32) if n >> 31 else n
                else:
                    n = self.t64(fs)
                    n = n - (1 << 64) if n >> 63 else n
                    if n >= 1 << 55 or n < -(1 << 55):
                        self.raise_(E); self.trap()
                bits, flags = round_to(to, Fraction(n), self.mode)
                (self.d32 if to is S else self.d64)(fd, self.finish(to, flags, bits))
                return
        self.raise_(E); self.trap()


class CopUnusable(Exception):
    """Status.CU1 is clear"""
