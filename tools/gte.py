"""A model of the PlayStation's GTE (COP2), the fixed-point geometry engine.

This is the reference the RTL is checked against, exactly as tools/mipsasm.py is
for the CPU: every quirk a game depends on -- the 44-bit accumulators and their
overflow flags, the saturating IR registers, the unsigned Newton-Raphson divide,
the depth-cue interpolation, the leading-zero count -- lives here, and the
hardware is right when it agrees with it across a random sweep.

Two banks of 32 words. The data bank (cop2d: MFC2/MTC2) holds the vectors, the
colour and the results; the control bank (cop2c: CFC2/CTC2) holds the matrices
and the projection constants. Values are kept as Python ints, masked to width on
write and given their sign on read, because that is what the silicon does and
the corners are where it matters.

Reference: Nocash PSX-SPX "GTE" pages.
"""

M32 = 0xFFFFFFFF


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def s32(v):
    v &= M32
    return v - 0x100000000 if v & 0x80000000 else v


def u32(v):
    return v & M32


def wrap44(v):
    """The accumulator is 44 bits on the chip and wraps there."""
    v &= (1 << 44) - 1
    return v - (1 << 44) if v & (1 << 43) else v


def mac32(v):
    """What the 32-bit MAC register holds, as a signed value: IR saturates off
    THIS, not off the wider accumulator."""
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v & (1 << 31) else v


class GTE:
    # --- flag bits ---------------------------------------------------------
    F_MAC1_P, F_MAC2_P, F_MAC3_P = 30, 29, 28     # 44-bit positive overflow
    F_MAC1_N, F_MAC2_N, F_MAC3_N = 27, 26, 25     # 44-bit negative overflow
    F_IR1, F_IR2, F_IR3 = 24, 23, 22              # IR saturated
    F_R, F_G, F_B = 21, 20, 19                    # colour FIFO saturated
    F_SZ = 18                                     # SZ3 / OTZ saturated
    F_DIV = 17                                    # divide overflow
    F_MAC0_P, F_MAC0_N = 16, 15                   # 32-bit overflow of MAC0
    F_SX, F_SY = 14, 13                           # SX2 / SY2 saturated
    F_IR0 = 12                                    # IR0 saturated

    def __init__(self):
        self.d = [0] * 32
        self.c = [0] * 32

    # ======================================================================
    # register moves
    # ======================================================================
    def write_data(self, i, v):
        v = u32(v)
        if i == 7:
            self.d[7] = v & 0xFFFF
        elif i == 15:                       # SXYP pushes the SXY fifo
            self.d[12] = self.d[13]
            self.d[13] = self.d[14]
            self.d[14] = v
            self.d[15] = v
        elif i == 28:                       # IRGB unpacks into IR1..3
            self.d[28] = v & 0x7FFF
            self.d[9] = (v & 0x1F) << 7
            self.d[10] = ((v >> 5) & 0x1F) << 7
            self.d[11] = ((v >> 10) & 0x1F) << 7
        elif i == 29 or i == 31:            # ORGB, LZCR are read-only
            pass
        elif i == 30:                       # LZCS -> LZCR
            self.d[30] = v
            self.d[31] = self.leadcount(v)
        else:
            self.d[i] = v

    # What a register reads back is not what was written: the 16-bit ones come
    # back sign- or zero-extended. Checked against a real machine through
    # JaCzekanski's gte-fuzz log; before this the model and the RTL agreed with
    # each other and both differed from the chip.
    SX_DATA = (1, 3, 5, 8, 9, 10, 11)          # VZ0..2, IR0..3: signed 16
    ZX_DATA = (7, 16, 17, 18, 19)              # OTZ, SZ0..3: unsigned 16
    SX_CTRL = (4, 12, 20, 26, 27, 29, 30)      # RT33, L33, LB3, H, DQA, ZSF3, ZSF4

    def read_data(self, i):
        if i == 15:
            return self.d[14]
        if i in self.SX_DATA:
            return u32(s16(self.d[i] & 0xFFFF))
        if i in self.ZX_DATA:
            return self.d[i] & 0xFFFF
        if i in (28, 29):
            r = self._clamp(s16(self.d[9]) >> 7, 0, 31)
            g = self._clamp(s16(self.d[10]) >> 7, 0, 31)
            b = self._clamp(s16(self.d[11]) >> 7, 0, 31)
            return r | (g << 5) | (b << 10)
        return self.d[i] & M32

    def write_ctrl(self, i, v):
        self.c[i] = u32(v)

    def read_ctrl(self, i):
        if i == 31:
            f = self.c[31] & 0x7FFFF000
            if f & 0x7F87E000:
                f |= 0x80000000
            return f
        if i in self.SX_CTRL:
            return u32(s16(self.c[i] & 0xFFFF))
        return self.c[i] & M32

    @staticmethod
    def leadcount(v):
        v &= M32
        top = (v >> 31) & 1
        n = 0
        for k in range(31, -1, -1):
            if ((v >> k) & 1) == top:
                n += 1
            else:
                break
        return n

    @staticmethod
    def _clamp(v, lo, hi):
        return lo if v < lo else hi if v > hi else v

    # ======================================================================
    # named views of the control bank
    # ======================================================================
    def _mat(self, base):
        c = self.c
        return [[s16(c[base]), s16(c[base] >> 16), s16(c[base + 1])],
                [s16(c[base + 1] >> 16), s16(c[base + 2]), s16(c[base + 2] >> 16)],
                [s16(c[base + 3]), s16(c[base + 3] >> 16), s16(c[base + 4])]]

    def RT(self): return self._mat(0)
    def LLM(self): return self._mat(8)
    def LCM(self): return self._mat(16)
    def TR(self): return (s32(self.c[5]), s32(self.c[6]), s32(self.c[7]))
    def BK(self): return (s32(self.c[13]), s32(self.c[14]), s32(self.c[15]))
    def FC(self): return (s32(self.c[21]), s32(self.c[22]), s32(self.c[23]))
    def OFX(self): return s32(self.c[24])
    def OFY(self): return s32(self.c[25])
    def H(self): return self.c[26] & 0xFFFF
    def DQA(self): return s16(self.c[27])
    def DQB(self): return s32(self.c[28])
    def ZSF3(self): return s16(self.c[29])
    def ZSF4(self): return s16(self.c[30])

    def V(self, n):
        lo, hi = self.d[2 * n], self.d[2 * n + 1]
        return (s16(lo), s16(lo >> 16), s16(hi))

    def IR(self, n): return s16(self.d[8 + n])
    def MAC(self, n): return s32(self.d[24 + n])

    def RGBC(self):
        v = self.d[6]
        return (v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF)

    # ======================================================================
    # the flag register and the saturating writes
    # ======================================================================
    def _flag(self, bit):
        self.c[31] |= (1 << bit)

    def _mac0(self, v):
        """MAC0 with 32-bit overflow flags."""
        if v > 0x7FFFFFFF: self._flag(self.F_MAC0_P)
        if v < -0x80000000: self._flag(self.F_MAC0_N)
        self.d[24] = u32(v)
        return v

    def _macn_check(self, v, n):
        """The 44-bit overflow check on an accumulator (n = 1..3)."""
        if v >= (1 << 43): self._flag(31 - n)        # 30,29,28
        if v < -(1 << 43): self._flag(28 - n)        # 27,26,25

    def _set_ir(self, n, v, lm):
        lo = 0 if lm else -0x8000
        if v < lo: self._flag(25 - n); v = lo
        elif v > 0x7FFF: self._flag(25 - n); v = 0x7FFF
        self.d[8 + n] = v & 0xFFFF

    def _set_ir0(self, v):
        if v < 0: self._flag(self.F_IR0); v = 0
        elif v > 0x1000: self._flag(self.F_IR0); v = 0x1000
        self.d[8] = v & 0xFFFF

    def _sat_sz(self, v):
        if v < 0: self._flag(self.F_SZ); return 0
        if v > 0xFFFF: self._flag(self.F_SZ); return 0xFFFF
        return v

    def _push_sz(self, v):
        self.d[16], self.d[17], self.d[18] = self.d[17], self.d[18], self.d[19]
        self.d[19] = v & 0xFFFF

    def _push_sxy(self, x, y):
        self.d[12], self.d[13] = self.d[13], self.d[14]
        self.d[14] = (x & 0xFFFF) | ((y & 0xFFFF) << 16)
        self.d[15] = self.d[14]

    def _sat_sx(self, v):
        if v < -0x400: self._flag(self.F_SX); return -0x400
        if v > 0x3FF: self._flag(self.F_SX); return 0x3FF
        return v

    def _sat_sy(self, v):
        if v < -0x400: self._flag(self.F_SY); return -0x400
        if v > 0x3FF: self._flag(self.F_SY); return 0x3FF
        return v

    def _push_color(self, r, g, b):
        code = (self.d[6] >> 24) & 0xFF
        rr = self._clamp(r, 0, 255); gg = self._clamp(g, 0, 255); bb = self._clamp(b, 0, 255)
        if rr != r: self._flag(self.F_R)
        if gg != g: self._flag(self.F_G)
        if bb != b: self._flag(self.F_B)
        self.d[20], self.d[21] = self.d[21], self.d[22]
        self.d[22] = rr | (gg << 8) | (bb << 16) | (code << 24)

    # ======================================================================
    # the shared datapath pieces
    # ======================================================================
    def _mvt(self, mat, vec, tr, shift, lm):
        """MAC1..3 = (TR<<12 + M*V) >> shift; IR1..3 = sat(MAC).  Returns MACs."""
        macs = []
        for r in range(3):
            acc = (tr[r] << 12) + mat[r][0] * vec[0] + mat[r][1] * vec[1] + mat[r][2] * vec[2]
            self._macn_check(acc, r + 1)
            m = wrap44(acc) >> shift
            self.d[25 + r] = u32(m)
            macs.append(m)
        for r in range(3):
            self._set_ir(r + 1, mac32(macs[r]), lm)
        return macs

    def _mac_to_color(self, macs, shift, lm):
        """MAC >> shift -> MAC, IR (lm); colour FIFO gets MAC/16."""
        out = []
        for r in range(3):
            m = macs[r] >> shift
            self.d[25 + r] = u32(m)
            out.append(m)
        for r in range(3):
            self._set_ir(r + 1, mac32(out[r]), lm)
        self._push_color(mac32(out[0]) >> 4, mac32(out[1]) >> 4, mac32(out[2]) >> 4)
        return out

    def _depth_cue(self, macs, shift):
        """MAC = MAC + (FC - MAC) * IR0, with the intermediate IR saturating
        as lm=0. Leaves the un-shifted MACs for the caller to finish."""
        fc = self.FC()
        ir0 = self.IR(0)
        out = []
        for r in range(3):
            diff = ((fc[r] << 12) - macs[r]) >> shift
            self._macn_check((fc[r] << 12) - macs[r], r + 1)
            # IR (lm=0) saturation on the difference, flag on the way through
            self._set_ir(r + 1, diff, 0)
            irv = self.IR(r + 1)
            v = irv * ir0 + macs[r]
            self._macn_check(v, r + 1)
            out.append(v)
        return out

    # the unsigned Newton-Raphson divide, with the chip's own seed table
    _UNR = None

    @classmethod
    def unr_table(cls):
        if cls._UNR is None:
            t = []
            for i in range(256):
                x = max(0, (0x40000 // (i + 0x100) + 1) // 2 - 0x101)
                t.append(x)
            t.append(0)
            cls._UNR = t
        return cls._UNR

    def divide(self, h, sz3):
        if h >= sz3 * 2:
            self._flag(self.F_DIV)
            return 0x1FFFF
        z = 0
        n = sz3
        while not (n & 0x8000):
            n <<= 1
            z += 1
        d = sz3 << z
        u = self.unr_table()[((d & 0x7FFF) + 0x40) >> 7] + 0x101
        d = (0x2000080 - (d * u)) >> 8
        d = (0x0000080 + (d * u)) >> 8
        r = ((h << z) * d + 0x8000) >> 16
        return min(0x1FFFF, r)

    # ======================================================================
    # commands
    # ======================================================================
    def op(self, word):
        self.c[31] = 0
        cmd = word & 0x3F
        shift = 12 if (word >> 19) & 1 else 0
        lm = (word >> 10) & 1
        mx = (word >> 17) & 3
        vx = (word >> 15) & 3
        cv = (word >> 13) & 3
        f = {
            0x01: lambda: self.rtps(0, True, shift, lm),
            0x06: self.nclip,
            0x0C: lambda: self.opc(shift, lm),
            0x10: lambda: self.dpcs(shift, lm, False),
            0x11: lambda: self.intpl(shift, lm),
            0x12: lambda: self.mvmva(shift, lm, mx, vx, cv),
            0x13: lambda: self.ncds(0, shift, lm),
            0x14: lambda: self.cdp(shift, lm),
            0x16: lambda: [self.ncds(i, shift, lm) for i in range(3)],
            0x1B: lambda: self.nccs(0, shift, lm),
            0x1C: lambda: self.cc(shift, lm),
            0x1E: lambda: self.ncs(0, shift, lm),
            0x20: lambda: [self.ncs(i, shift, lm) for i in range(3)],
            0x28: lambda: self.sqr(shift, lm),
            0x29: lambda: self.dcpl(shift, lm),
            0x2A: lambda: self.dpcs(shift, lm, True),
            0x2D: lambda: self.avsz(3),
            0x2E: lambda: self.avsz(4),
            0x30: lambda: [self.rtps(i, i == 2, shift, lm) for i in range(3)],
            0x3D: lambda: self.gpf(shift, lm),
            0x3E: lambda: self.gpl(shift, lm),
            0x3F: lambda: [self.nccs(i, shift, lm) for i in range(3)],
        }.get(cmd)
        if f:
            f()

    # --- perspective transform ------------------------------------------
    def rtps(self, n, do_dq, shift, lm):
        rt, tr, v = self.RT(), self.TR(), self.V(n)
        macs = []
        for r in range(3):
            acc = (tr[r] << 12) + rt[r][0] * v[0] + rt[r][1] * v[1] + rt[r][2] * v[2]
            self._macn_check(acc, r + 1)
            macs.append(wrap44(acc) >> shift)
            self.d[25 + r] = u32(macs[r])
        self._set_ir(1, mac32(macs[0]), lm)
        self._set_ir(2, mac32(macs[1]), lm)
        # IR3's saturation FLAG is judged on MAC3>>12 whatever sf is; the value
        # stored is the plain clamp.
        chk = macs[2] >> (12 - shift)
        if chk < -0x8000 or chk > 0x7FFF:
            self._flag(self.F_IR3)
        self.d[11] = self._clamp(mac32(macs[2]), 0 if lm else -0x8000, 0x7FFF) & 0xFFFF
        sz = self._sat_sz(macs[2] >> (12 - shift))
        self._push_sz(sz)
        q = self.divide(self.H(), self.d[19])
        sx = self.OFX() + self.IR(1) * q
        sy = self.OFY() + self.IR(2) * q
        self._mac0(sx)
        self._mac0(sy)
        # the screen coordinate comes off a MAC0 that SATURATES, not one that
        # wraps: IR * (H/SZ) overflows 32 bits routinely and the chip still
        # projects a positive overflow to the right-hand edge
        def sat32sh(v):
            if v > 0x7FFFFFFF:  return 0x7FFF
            if v < -0x80000000: return -0x8000
            return s32(v) >> 16
        self._push_sxy(self._sat_sx(sat32sh(sx)), self._sat_sy(sat32sh(sy)))
        if do_dq:
            dq = self.DQB() + self.DQA() * q
            self._mac0(dq)
            self._set_ir0(s32(dq) >> 12)

    def nclip(self):
        sx0, sy0 = s16(self.d[12]), s16(self.d[12] >> 16)
        sx1, sy1 = s16(self.d[13]), s16(self.d[13] >> 16)
        sx2, sy2 = s16(self.d[14]), s16(self.d[14] >> 16)
        self._mac0(sx0 * sy1 + sx1 * sy2 + sx2 * sy0 - sx0 * sy2 - sx1 * sy0 - sx2 * sy1)

    def avsz(self, n):
        if n == 3:
            v = self.ZSF3() * (self.d[17] + self.d[18] + self.d[19])
        else:
            v = self.ZSF4() * (self.d[16] + self.d[17] + self.d[18] + self.d[19])
        self._mac0(v)
        self.d[7] = self._sat_sz(v >> 12) & 0xFFFF

    def sqr(self, shift, lm):
        macs = [(self.IR(i) * self.IR(i)) >> shift for i in (1, 2, 3)]
        for r in range(3):
            self.d[25 + r] = u32(macs[r])
            self._set_ir(r + 1, macs[r], lm)

    def opc(self, shift, lm):
        d1, d2, d3 = s16(self.c[0]), s16(self.c[2]), s16(self.c[4])
        i1, i2, i3 = self.IR(1), self.IR(2), self.IR(3)
        raw = [i3 * d2 - i2 * d3, i1 * d3 - i3 * d1, i2 * d1 - i1 * d2]
        for r in range(3):
            self._macn_check(raw[r], r + 1)
            m = raw[r] >> shift
            self.d[25 + r] = u32(m)
            raw[r] = m
        for r in range(3):
            self._set_ir(r + 1, raw[r], lm)

    def mvmva(self, shift, lm, mx, vx, cv):
        if mx == 0: mat = self.RT()
        elif mx == 1: mat = self.LLM()
        elif mx == 2: mat = self.LCM()
        else:
            # the "garbage matrix" the chip really uses for mx=3
            r, g, b, _ = self.RGBC()
            i1 = self.IR(0)
            mat = [[-((r << 4)), (r << 4), i1],
                   [s16(self.c[2]), s16(self.c[2]), s16(self.c[2])],
                   [s16(self.c[4]), s16(self.c[4]), s16(self.c[4])]]
        vec = self.V(vx) if vx < 3 else (self.IR(1), self.IR(2), self.IR(3))
        if cv == 0: tr = self.TR()
        elif cv == 1: tr = self.BK()
        elif cv == 2: tr = self.FC()
        else: tr = (0, 0, 0)
        if cv == 2:
            # the hardware bug: with FC selected only the last column of the
            # product survives the translation add; the flags see the first
            # column added to FC.
            macs = []
            for r in range(3):
                first = (tr[r] << 12) + mat[r][0] * vec[0]
                self._macn_check(first, r + 1)
                self._set_ir(r + 1, first >> shift, 0)
                acc = mat[r][1] * vec[1] + mat[r][2] * vec[2]
                self._macn_check(acc, r + 1)
                m = acc >> shift
                self.d[25 + r] = u32(m)
                macs.append(m)
            for r in range(3):
                self._set_ir(r + 1, macs[r], lm)
            return
        self._mvt(mat, vec, tr, shift, lm)

    # --- lighting --------------------------------------------------------
    def _light(self, n, shift, lm):
        self._mvt(self.LLM(), self.V(n), (0, 0, 0), shift, lm)
        ir = (self.IR(1), self.IR(2), self.IR(3))
        self._mvt(self.LCM(), ir, self.BK(), shift, lm)

    def _rgb_times_ir(self):
        r, g, b, _ = self.RGBC()
        return [(r * self.IR(1)) << 4, (g * self.IR(2)) << 4, (b * self.IR(3)) << 4]

    def ncds(self, n, shift, lm):
        self._light(n, shift, lm)
        macs = self._rgb_times_ir()
        macs = self._depth_cue(macs, shift)
        self._mac_to_color(macs, shift, lm)

    def nccs(self, n, shift, lm):
        self._light(n, shift, lm)
        self._mac_to_color(self._rgb_times_ir(), shift, lm)

    def ncs(self, n, shift, lm):
        self._light(n, shift, lm)
        macs = [self.MAC(1), self.MAC(2), self.MAC(3)]
        self._push_color(macs[0] >> 4, macs[1] >> 4, macs[2] >> 4)

    def cc(self, shift, lm):
        ir = (self.IR(1), self.IR(2), self.IR(3))
        self._mvt(self.LCM(), ir, self.BK(), shift, lm)
        self._mac_to_color(self._rgb_times_ir(), shift, lm)

    def cdp(self, shift, lm):
        ir = (self.IR(1), self.IR(2), self.IR(3))
        self._mvt(self.LCM(), ir, self.BK(), shift, lm)
        macs = self._depth_cue(self._rgb_times_ir(), shift)
        self._mac_to_color(macs, shift, lm)

    def dcpl(self, shift, lm):
        macs = self._depth_cue(self._rgb_times_ir(), shift)
        self._mac_to_color(macs, shift, lm)

    def dpcs(self, shift, lm, triple):
        reps = 3 if triple else 1
        for _ in range(reps):
            if triple:
                v = self.d[20]
                r, g, b = v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF
            else:
                r, g, b, _c = self.RGBC()
            macs = [r << 16, g << 16, b << 16]
            macs = self._depth_cue(macs, shift)
            self._mac_to_color(macs, shift, lm)

    def intpl(self, shift, lm):
        macs = [self.IR(1) << 12, self.IR(2) << 12, self.IR(3) << 12]
        macs = self._depth_cue(macs, shift)
        self._mac_to_color(macs, shift, lm)

    def gpf(self, shift, lm):
        ir0 = self.IR(0)
        macs = [ir0 * self.IR(1), ir0 * self.IR(2), ir0 * self.IR(3)]
        self._mac_to_color(macs, shift, lm)

    def gpl(self, shift, lm):
        ir0 = self.IR(0)
        macs = [(self.MAC(i) << shift) + ir0 * self.IR(i) for i in (1, 2, 3)]
        for r in range(3):
            self._macn_check(macs[r], r + 1)
        self._mac_to_color(macs, shift, lm)


if __name__ == "__main__":
    g = GTE()
    # identity rotation, H=0x200, a vertex at z=0x400 -> lands on screen
    g.write_ctrl(0, 0x1000)                   # RT11=1.0, RT12=0
    g.write_ctrl(2, 0x1000)                   # RT22=1.0
    g.write_ctrl(4, 0x1000)                   # RT33=1.0
    g.write_ctrl(26, 0x200)                   # H
    g.write_data(0, (0x0080 & 0xFFFF) | ((0x0040 & 0xFFFF) << 16))
    g.write_data(1, 0x0400)
    g.op(0x00080001)                          # RTPS, sf=1
    print("MAC1..3 :", g.MAC(1), g.MAC(2), g.MAC(3))
    print("SZ3     :", g.d[19])
    print("SXY2    :", s16(g.d[14]), s16(g.d[14] >> 16))
    print("FLAG    :", hex(g.read_ctrl(31)))
