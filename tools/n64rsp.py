"""The N64's RSP, for tools/n64model.py: the scalar unit, its COP0 (the SP's
DMA and status, and the DP's registers), and the vector unit (COP2).

Behaviour follows ares (ares/n64/rsp, ISC): interpreter-ipu.cpp for the scalar
unit, interpreter-scc.cpp and io.cpp and dma.cpp for COP0, and the per-element
(SISD) paths of interpreter-vpu.cpp for the vector unit, operation for
operation. No timing: an instruction a step, a DMA done the moment it is asked
for.

Layout: DMEM and IMEM are the bus's own 4 kB bytearrays. A vector register is
a bytearray of 16, byte 0 the most significant, as ares's r128.byte(); element
n is bytes 2n (high) and 2n+1. The accumulator is three lists of eight 16-bit
words (high, middle, low); the flags VCO, VCC and VCE are lists of eight
booleans (the high and low halves of VCO and VCC separately).
"""

M32 = 0xFFFFFFFF


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def s32(v):
    v &= M32
    return v - (1 << 32) if v & 0x80000000 else v


def sclamp16(v):
    return -32768 if v < -32768 else 32767 if v > 32767 else v


def sclip48(v):
    v &= (1 << 48) - 1
    return v - (1 << 48) if v & (1 << 47) else v


def clz32(v):
    return 32 - (v & M32).bit_length()


# vt(e): the element pattern each of the 16 values of e picks (ares r128::operator())
_BCAST = [list(range(8)), list(range(8)),
          [0, 0, 2, 2, 4, 4, 6, 6], [1, 1, 3, 3, 5, 5, 7, 7],
          [0, 0, 0, 0, 4, 4, 4, 4], [1, 1, 1, 1, 5, 5, 5, 5],
          [2, 2, 2, 2, 6, 6, 6, 6], [3, 3, 3, 3, 7, 7, 7, 7]] + [[k] * 8 for k in range(8)]


class RSP:
    def __init__(self, bus):
        self.bus = bus
        self.dmem = bus.dmem
        self.imem = bus.imem
        self.r = [0] * 32
        self.pc = 0
        self.npc = 4
        # COP0: the status register's parts
        self.halted = 1
        self.broken = 0
        self.full = 0
        self.single_step = 0
        self.int_on_break = 0
        self.signal = [0] * 8
        self.semaphore = 0
        # the DMA: what is set up next (pending) and what last ran (current)
        self.pend = dict(pbus=0, region=0, dram=0, length=0, count=0, skip=0)
        self.cur = dict(pbus=0, region=0, dram=0, length=0, count=0, skip=0)
        # the DP's registers, stored (the RDP itself is not here yet)
        self.dp = [0] * 8
        # the vector unit
        self.vr = [bytearray(16) for _ in range(32)]
        self.acch = [0] * 8
        self.accm = [0] * 8
        self.accl = [0] * 8
        self.vcoh = [False] * 8
        self.vcol = [False] * 8
        self.vcch = [False] * 8
        self.vccl = [False] * 8
        self.vce = [False] * 8
        self.divin = 0
        self.divout = 0
        self.divdp = 0
        self.recip = [0] * 512
        self.rsqrt = [0] * 512
        self.recip[0] = 0xFFFF
        for i in range(1, 512):
            a = i + 512
            b = (1 << 34) // a
            self.recip[i] = ((b + 1) >> 8) & 0xFFFF
        for i in range(512):
            a = (i + 512) >> (i & 1)
            b = 1 << 17
            while a * (b + 1) * (b + 1) < (1 << 44):
                b += 1
            self.rsqrt[i] = (b >> 1) & 0xFFFF
        self.instructions = 0

    # --- memory ------------------------------------------------------------------------
    def db(self, a):
        return self.dmem[a & 0xFFF]

    def dwb(self, a, v):
        self.dmem[a & 0xFFF] = v & 0xFF

    def dread(self, a, n):                 # readUnaligned: byte by byte, wrapping at 4 kB
        v = 0
        for i in range(n):
            v = (v << 8) | self.dmem[(a + i) & 0xFFF]
        return v

    def dwrite(self, a, n, v):
        for i in range(n):
            self.dmem[(a + i) & 0xFFF] = (v >> (8 * (n - 1 - i))) & 0xFF

    # --- the vector registers ---------------------------------------------------------------
    @staticmethod
    def el(v, n):
        return (v[2 * n] << 8) | v[2 * n + 1]

    @staticmethod
    def set_el(v, n, x):
        v[2 * n] = (x >> 8) & 0xFF
        v[2 * n + 1] = x & 0xFF

    def vte(self, t, e):
        """vt(e) as eight unsigned 16-bit elements"""
        v = self.vr[t]
        return [self.el(v, k) for k in _BCAST[e]]

    def vs_u(self, s):
        v = self.vr[s]
        return [self.el(v, n) for n in range(8)]

    def store_vd(self, d, vals):
        v = self.vr[d]
        for n in range(8):
            self.set_el(v, n, vals[n])

    def acc_get(self, n):
        return (self.acch[n] << 32) | (self.accm[n] << 16) | self.accl[n]

    def acc_set(self, n, v):
        self.acch[n] = (v >> 32) & 0xFFFF
        self.accm[n] = (v >> 16) & 0xFFFF
        self.accl[n] = v & 0xFFFF

    def acc_sat(self, n, slice_, neg, pos):
        if s16(self.acch[n]) < 0:
            if self.acch[n] != 0xFFFF:
                return neg
            if s16(self.accm[n]) >= 0:
                return neg
        else:
            if self.acch[n] != 0:
                return pos
            if s16(self.accm[n]) < 0:
                return pos
        return self.accm[n] if slice_ else self.accl[n]

    # --- the step ---------------------------------------------------------------------------
    def step(self):
        if self.halted:
            return
        self.instructions += 1
        pc = self.pc
        w = int.from_bytes(self.imem[pc & 0xFFC:(pc & 0xFFC) + 4], 'big')
        self.pc, self.npc = self.npc, (self.npc + 4) & 0xFFC
        self.execute(w, pc)
        self.r[0] = 0

    def set_pc(self, v):
        """SP_PC written: the next instruction is there"""
        self.pc = v & 0xFFC
        self.npc = (self.pc + 4) & 0xFFC

    def take(self, target):
        self.npc = target & 0xFFC

    def execute(self, w, pc):
        op = w >> 26
        rs = (w >> 21) & 31
        rt = (w >> 16) & 31
        rd = (w >> 11) & 31
        sa = (w >> 6) & 31
        imm = w & 0xFFFF
        simm = imm - 0x10000 if imm & 0x8000 else imm
        r = self.r
        if op == 0x00:
            fn = w & 63
            a, b = r[rs], r[rt]
            if fn == 0x00: r[rd] = (b << sa) & M32
            elif fn == 0x02: r[rd] = b >> sa
            elif fn == 0x03: r[rd] = (s32(b) >> sa) & M32
            elif fn == 0x04: r[rd] = (b << (a & 31)) & M32
            elif fn == 0x06: r[rd] = b >> (a & 31)
            elif fn == 0x07: r[rd] = (s32(b) >> (a & 31)) & M32
            elif fn == 0x08: self.take(a)
            elif fn == 0x09: self.take(a); r[rd] = (pc + 8) & 0xFFF
            elif fn == 0x0D:                                      # BREAK
                self.halted = 1
                self.broken = 1
                if self.int_on_break:
                    self.bus.mi_intr |= 0x01
            elif fn in (0x20, 0x21): r[rd] = (a + b) & M32
            elif fn in (0x22, 0x23): r[rd] = (a - b) & M32
            elif fn == 0x24: r[rd] = a & b
            elif fn == 0x25: r[rd] = a | b
            elif fn == 0x26: r[rd] = a ^ b
            elif fn == 0x27: r[rd] = ~(a | b) & M32
            elif fn == 0x2A: r[rd] = int(s32(a) < s32(b))
            elif fn == 0x2B: r[rd] = int(a < b)
            else:
                # SPECIAL_INVALID: SRLV(rd, rs, rs) -- rs shifted by itself
                r[rd] = a >> (a & 31)
            return
        if op == 0x01:
            a = s32(r[rs])
            tgt = pc + 4 + (simm << 2)
            if rt in (0x00, 0x10):
                if a < 0: self.take(tgt)
            elif rt in (0x01, 0x11):
                if a >= 0: self.take(tgt)
            else:
                return
            if rt & 0x10:
                r[31] = (pc + 8) & 0xFFF
            return
        if op == 0x02: self.take((w & 0x3FFFFFF) << 2); return
        if op == 0x03: r[31] = (pc + 8) & 0xFFF; self.take((w & 0x3FFFFFF) << 2); return
        tgt = pc + 4 + (simm << 2)
        if op == 0x04:
            if r[rs] == r[rt]: self.take(tgt)
            return
        if op == 0x05:
            if r[rs] != r[rt]: self.take(tgt)
            return
        if op == 0x06:
            if s32(r[rs]) <= 0: self.take(tgt)
            return
        if op == 0x07:
            if s32(r[rs]) > 0: self.take(tgt)
            return
        if op in (0x08, 0x09): r[rt] = (r[rs] + simm) & M32; return
        if op == 0x0A: r[rt] = int(s32(r[rs]) < simm); return
        if op == 0x0B: r[rt] = int(r[rs] < (simm & M32)); return
        if op == 0x0C: r[rt] = r[rs] & imm; return
        if op == 0x0D: r[rt] = r[rs] | imm; return
        if op == 0x0E: r[rt] = r[rs] ^ imm; return
        if op == 0x0F: r[rt] = (imm << 16) & M32; return
        if op == 0x10: self.scc(w, rs, rt, rd); return
        if op == 0x12: self.vu(w, rs, rt, rd); return
        a = (r[rs] + simm) & M32
        if op == 0x20: v = self.db(a); r[rt] = (v | ~0xFF) & M32 if v & 0x80 else v; return
        if op == 0x21: v = self.dread(a, 2); r[rt] = (v | ~0xFFFF) & M32 if v & 0x8000 else v; return
        if op in (0x23, 0x27): r[rt] = self.dread(a, 4); return
        if op == 0x24: r[rt] = self.db(a); return
        if op == 0x25: r[rt] = self.dread(a, 2); return
        if op == 0x28: self.dwb(a, r[rt]); return
        if op == 0x29: self.dwrite(a, 2, r[rt]); return
        if op == 0x2B: self.dwrite(a, 4, r[rt]); return
        if op == 0x32: self.lwc2(w, rs, rt); return
        if op == 0x3A: self.swc2(w, rs, rt); return
        # everything else does nothing on the RSP

    # --- COP0 -------------------------------------------------------------------------------
    def scc(self, w, rs, rt, rd):
        if rs == 0x00:
            v = self.sp_read(rd & 7) if not rd & 8 else self.dp_read(rd & 7)
            if rt:
                self.r[rt] = v & M32
        elif rs == 0x04:
            if not rd & 8:
                self.sp_write(rd & 7, self.r[rt])
            else:
                self.dp_write(rd & 7, self.r[rt])

    def sp_read(self, i):
        """the SP's registers (ares RSP::ioRead), as the CPU and the RSP see them"""
        c = self.cur
        if i == 0: return (c['pbus'] & 0xFFF) | (c['region'] << 12)
        if i == 1: return c['dram'] & 0xFFFFFF
        if i in (2, 3): return (c['length'] & 0xFFF) | ((c['count'] & 0xFF) << 12) | ((c['skip'] & 0xFFF) << 20)
        if i == 4:
            v = self.halted | (self.broken << 1) | (self.full << 4) | (self.single_step << 5) | (self.int_on_break << 6)
            for k in range(8):
                v |= self.signal[k] << (7 + k)
            return v
        if i in (5, 6): return 0                  # no DMA is ever full or busy: they are done at once
        if i == 7:
            v = self.semaphore
            self.semaphore = 1
            return v
        return 0

    def sp_write(self, i, v):
        p = self.pend
        if i == 0:
            p['pbus'] = v & 0xFF8
            p['region'] = (v >> 12) & 1
        elif i == 1:
            p['dram'] = v & 0xFFFFF8
        elif i in (2, 3):
            p['length'] = v & 0xFF8
            p['count'] = (v >> 12) & 0xFF
            p['skip'] = ((v >> 23) & 0x1FF) << 3
            self.dma(read=(i == 2))
        elif i == 4:
            if v & 1 and not v & 2: self.halted = 0
            if v & 2 and not v & 1: self.halted = 1
            if v & 4: self.broken = 0
            if v & 8 and not v & 16: self.bus.mi_intr &= ~0x01
            if v & 16 and not v & 8: self.bus.mi_intr |= 0x01
            if v & 32 and not v & 64: self.single_step = 0
            if v & 64 and not v & 32: self.single_step = 1
            if v & 128 and not v & 256: self.int_on_break = 0
            if v & 256 and not v & 128: self.int_on_break = 1
            for k in range(8):
                c, s = 9 + 2 * k, 10 + 2 * k
                if v >> c & 1 and not v >> s & 1: self.signal[k] = 0
                if v >> s & 1 and not v >> c & 1: self.signal[k] = 1
        elif i == 7:
            self.semaphore = 0

    def dma(self, read):
        """a DMA between RDRAM and DMEM/IMEM, done at once (ares RSP::dmaTransferStep)"""
        c = dict(self.pend)
        rd = self.bus.rdram
        mem = self.imem if c['region'] else self.dmem
        while True:
            for _ in range(0, c['length'] + 1, 8):
                d, pb = c['dram'] & 0xFFFFF8, c['pbus'] & 0xFF8
                if read:
                    mem[pb:pb + 8] = rd[d:d + 8]
                else:
                    rd[d:d + 8] = mem[pb:pb + 8]
                    self.bus.rdram_writes += 1
                c['dram'] = (c['dram'] + 8) & 0xFFFFFF
                c['pbus'] = (c['pbus'] + 8) & 0xFFF
            if c['count']:
                c['count'] -= 1
                c['dram'] = (c['dram'] + c['skip']) & 0xFFFFFF
            else:
                break
        c['length'] = 0xFF8
        self.cur = c

    def dp_read(self, i):
        rdp = getattr(self.bus, 'rdp', None)            # the one RDP the CPU sees too (tools/n64rdp.py)
        return rdp.reg_read(i) if rdp is not None else self.dp[i]

    def dp_write(self, i, v):
        rdp = getattr(self.bus, 'rdp', None)
        if rdp is not None:
            rdp.reg_write(i, v)
        else:
            self.dp[i] = v & M32

    # --- COP2: moves --------------------------------------------------------------------------
    def vu(self, w, rs, rt, rd):
        r = self.r
        if not (w >> 25) & 1:
            e = (w >> 7) & 15
            if rs == 0x00:                                        # MFC2
                if rt:
                    v = self.vr[rd]
                    r[rt] = s16((v[e & 15] << 8) | v[(e + 1) & 15]) & M32
            elif rs == 0x02:                                      # CFC2
                if rt:
                    hi, lo = {0: (self.vcoh, self.vcol), 1: (self.vcch, self.vccl)}.get(rd & 3, ([False] * 8, self.vce))
                    v = 0
                    for n in range(8):
                        v |= int(lo[n]) << n
                        v |= int(hi[n]) << (8 + n)
                    r[rt] = s16(v) & M32
            elif rs == 0x04:                                      # MTC2
                v = self.vr[rd]
                v[e] = (r[rt] >> 8) & 0xFF
                if e != 15:
                    v[e + 1] = r[rt] & 0xFF
            elif rs == 0x06:                                      # CTC2
                if rd & 3 == 0: hi, lo = self.vcoh, self.vcol
                elif rd & 3 == 1: hi, lo = self.vcch, self.vccl
                else: hi, lo = [False] * 8, self.vce
                for n in range(8):
                    lo[n] = bool(r[rt] & (1 << n))
                    hi[n] = bool(r[rt] & (1 << (8 + n)))
            return
        self.vop(w)

    # --- COP2: the operations -------------------------------------------------------------------
    def vop(self, w):
        fn = w & 63
        e = (w >> 21) & 15
        t = (w >> 16) & 31
        s = (w >> 11) & 31
        d = (w >> 6) & 31
        vte = self.vte(t, e)
        vs = self.vs_u(s)
        acch, accm, accl = self.acch, self.accm, self.accl
        out = None
        if fn in (0x00, 0x01):
            out = [0] * 8
            for n in range(8):
                self.acc_set(n, s16(vs[n]) * s16(vte[n]) * 2 + 0x8000)
                out[n] = self._mulf_out(n, fn & 1)
        elif fn in (0x08, 0x09):
            out = [0] * 8
            for n in range(8):
                self.acc_set(n, self.acc_get(n) + s16(vs[n]) * s16(vte[n]) * 2)
                if fn & 1:
                    out[n] = 0 if s16(acch[n]) < 0 else 0xFFFF if (s16(acch[n]) or s16(accm[n]) < 0) else accm[n]
                else:
                    out[n] = self.acc_sat(n, 1, 0x8000, 0x7FFF)
        elif fn in (0x02, 0x0A):                                  # VRNDP VRNDN (D = 1 for VRNDP)
            dflag = 1 if fn == 0x02 else 0
            out = [0] * 8
            for n in range(8):
                product = s16(vte[n])
                if s & 1:
                    product <<= 16
                acc = sclip48(self.acc_get(n))
                if (dflag == 0 and acc < 0) or (dflag == 1 and acc >= 0):
                    acc = sclip48(acc + product)
                self.acc_set(n, acc)
                out[n] = sclamp16(acc >> 16) & 0xFFFF
        elif fn == 0x03:                                          # VMULQ
            out = [0] * 8
            for n in range(8):
                product = s16(vs[n]) * s16(vte[n])
                if product < 0:
                    product += 31
                acch[n] = (product >> 16) & 0xFFFF
                accm[n] = product & 0xFFFF
                accl[n] = 0
                out[n] = sclamp16(product >> 1) & ~15 & 0xFFFF
        elif fn == 0x0B:                                          # VMACQ
            out = [0] * 8
            for n in range(8):
                product = s32((acch[n] << 16) | accm[n])
                if product < 0 and not product & 32:
                    product += 32
                elif product >= 32 and not product & 32:
                    product -= 32
                acch[n] = (product >> 16) & 0xFFFF
                accm[n] = product & 0xFFFF
                out[n] = sclamp16(product >> 1) & ~15 & 0xFFFF
        elif fn == 0x04:                                          # VMUDL
            for n in range(8):
                self.acc_set(n, ((vs[n] * vte[n]) >> 16) & 0xFFFF)
            out = list(accl)
        elif fn == 0x05:                                          # VMUDM
            for n in range(8):
                self.acc_set(n, s16(vs[n]) * vte[n])
            out = list(accm)
        elif fn == 0x06:                                          # VMUDN
            for n in range(8):
                self.acc_set(n, vs[n] * s16(vte[n]))
            out = list(accl)
        elif fn == 0x07:                                          # VMUDH
            out = [0] * 8
            for n in range(8):
                self.acc_set(n, (s16(vs[n]) * s16(vte[n])) << 16)
                out[n] = self.acc_sat(n, 1, 0x8000, 0x7FFF)
        elif fn == 0x0C:                                          # VMADL
            out = [0] * 8
            for n in range(8):
                self.acc_set(n, self.acc_get(n) + (((vs[n] * vte[n]) & M32) >> 16))
                out[n] = self.acc_sat(n, 0, 0x0000, 0xFFFF)
        elif fn == 0x0D:                                          # VMADM
            out = [0] * 8
            for n in range(8):
                self.acc_set(n, self.acc_get(n) + s16(vs[n]) * vte[n])
                out[n] = self.acc_sat(n, 1, 0x8000, 0x7FFF)
        elif fn == 0x0E:                                          # VMADN
            out = [0] * 8
            for n in range(8):
                self.acc_set(n, self.acc_get(n) + vs[n] * s16(vte[n]))
                out[n] = self.acc_sat(n, 0, 0x0000, 0xFFFF)
        elif fn == 0x0F:                                          # VMADH
            out = [0] * 8
            for n in range(8):
                result = s32((self.acc_get(n) >> 16) + s16(vs[n]) * s16(vte[n]))
                acch[n] = (result >> 16) & 0xFFFF
                accm[n] = result & 0xFFFF
                out[n] = self.acc_sat(n, 1, 0x8000, 0x7FFF)
        elif fn == 0x10:                                          # VADD
            out = [0] * 8
            for n in range(8):
                result = s16(vs[n]) + s16(vte[n]) + int(self.vcol[n])
                accl[n] = result & 0xFFFF
                out[n] = sclamp16(result) & 0xFFFF
            self.vcol = [False] * 8
            self.vcoh = [False] * 8
        elif fn == 0x11:                                          # VSUB
            out = [0] * 8
            for n in range(8):
                result = s16(vs[n]) - s16(vte[n]) - int(self.vcol[n])
                accl[n] = result & 0xFFFF
                out[n] = sclamp16(result) & 0xFFFF
            self.vcol = [False] * 8
            self.vcoh = [False] * 8
        elif fn == 0x13:                                          # VABS
            out = [0] * 8
            for n in range(8):
                a, b = s16(vs[n]), s16(vte[n])
                if a < 0:
                    if b == -32768:
                        accl[n] = 0x8000; out[n] = 0x7FFF
                    else:
                        accl[n] = (-b) & 0xFFFF; out[n] = (-b) & 0xFFFF
                elif a > 0:
                    accl[n] = b & 0xFFFF; out[n] = b & 0xFFFF
                else:
                    accl[n] = 0; out[n] = 0
        elif fn == 0x14:                                          # VADDC
            for n in range(8):
                result = vs[n] + vte[n]
                accl[n] = result & 0xFFFF
                self.vcol[n] = bool(result >> 16)
            self.vcoh = [False] * 8
            out = list(accl)
        elif fn == 0x15:                                          # VSUBC
            for n in range(8):
                result = (vs[n] - vte[n]) & M32
                accl[n] = result & 0xFFFF
                self.vcol[n] = bool(result >> 16)
                self.vcoh[n] = result != 0
            out = list(accl)
        elif fn == 0x1D:                                          # VSAR
            out = list(acch) if e == 8 else list(accm) if e == 9 else list(accl) if e == 10 else [0] * 8
        elif fn in (0x12, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1E, 0x1F, 0x2E, 0x2F,
                    0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E):    # VZERO: the unimplemented ones
            for n in range(8):
                accl[n] = (s16(vs[n]) + s16(vte[n])) & 0xFFFF
            out = [0] * 8
        elif fn == 0x20:                                          # VLT
            for n in range(8):
                c = s16(vs[n]) < s16(vte[n]) or (vs[n] == vte[n] and self.vcol[n] and self.vcoh[n])
                self.vccl[n] = c
                accl[n] = vs[n] if c else vte[n]
            self.vcch = [False] * 8; self.vcol = [False] * 8; self.vcoh = [False] * 8
            out = list(accl)
        elif fn == 0x21:                                          # VEQ
            for n in range(8):
                c = not self.vcoh[n] and vs[n] == vte[n]
                self.vccl[n] = c
                accl[n] = vs[n] if c else vte[n]
            self.vcch = [False] * 8; self.vcol = [False] * 8; self.vcoh = [False] * 8
            out = list(accl)
        elif fn == 0x22:                                          # VNE
            for n in range(8):
                c = vs[n] != vte[n] or self.vcoh[n]
                self.vccl[n] = c
                accl[n] = vs[n] if c else vte[n]
            self.vcch = [False] * 8; self.vcol = [False] * 8; self.vcoh = [False] * 8
            out = list(accl)
        elif fn == 0x23:                                          # VGE
            for n in range(8):
                c = s16(vs[n]) > s16(vte[n]) or (vs[n] == vte[n] and (not self.vcol[n] or not self.vcoh[n]))
                self.vccl[n] = c
                accl[n] = vs[n] if c else vte[n]
            self.vcch = [False] * 8; self.vcol = [False] * 8; self.vcoh = [False] * 8
            out = list(accl)
        elif fn == 0x24:                                          # VCL
            for n in range(8):
                a, b = vs[n], vte[n]
                if self.vcol[n]:
                    if self.vcoh[n]:
                        accl[n] = (-b) & 0xFFFF if self.vccl[n] else a
                    else:
                        total = a + b
                        sum_ = total & 0xFFFF
                        carry = total != sum_
                        if self.vce[n]:
                            c = (not sum_) or (not carry)
                        else:
                            c = (not sum_) and (not carry)
                        self.vccl[n] = c
                        accl[n] = (-b) & 0xFFFF if c else a
                else:
                    if self.vcoh[n]:
                        accl[n] = b if self.vcch[n] else a
                    else:
                        c = a - b >= 0
                        self.vcch[n] = c
                        accl[n] = b if c else a
            self.vcol = [False] * 8; self.vcoh = [False] * 8; self.vce = [False] * 8
            out = list(accl)
        elif fn == 0x25:                                          # VCH
            for n in range(8):
                a, b = s16(vs[n]), s16(vte[n])
                if (a ^ b) < 0:
                    result = s16(a + b)
                    accl[n] = (-b if result <= 0 else a) & 0xFFFF
                    self.vccl[n] = result <= 0
                    self.vcch[n] = b < 0
                    self.vcol[n] = True
                    self.vcoh[n] = result != 0 and vs[n] != (vte[n] ^ 0xFFFF)
                    self.vce[n] = result == -1
                else:
                    result = s16(a - b)
                    accl[n] = (b if result >= 0 else a) & 0xFFFF
                    self.vccl[n] = b < 0
                    self.vcch[n] = result >= 0
                    self.vcol[n] = False
                    self.vcoh[n] = result != 0 and vs[n] != (vte[n] ^ 0xFFFF)
                    self.vce[n] = False
            out = list(accl)
        elif fn == 0x26:                                          # VCR
            for n in range(8):
                a, b = s16(vs[n]), s16(vte[n])
                if (a ^ b) < 0:
                    self.vcch[n] = b < 0
                    c = a + b + 1 <= 0
                    self.vccl[n] = c
                    accl[n] = (~vte[n]) & 0xFFFF if c else vs[n]
                else:
                    self.vccl[n] = b < 0
                    c = a - b >= 0
                    self.vcch[n] = c
                    accl[n] = vte[n] if c else vs[n]
            self.vcol = [False] * 8; self.vcoh = [False] * 8; self.vce = [False] * 8
            out = list(accl)
        elif fn == 0x27:                                          # VMRG
            for n in range(8):
                accl[n] = vs[n] if self.vccl[n] else vte[n]
            self.vcoh = [False] * 8; self.vcol = [False] * 8
            out = list(accl)
        elif 0x28 <= fn <= 0x2D:                                  # VAND VNAND VOR VNOR VXOR VNXOR
            for n in range(8):
                a, b = vs[n], vte[n]
                v = (a & b, ~(a & b), a | b, ~(a | b), a ^ b, ~(a ^ b))[fn - 0x28]
                accl[n] = v & 0xFFFF
            out = list(accl)
        elif fn in (0x30, 0x31, 0x34, 0x35):                      # VRCP VRCPL VRSQ VRSQL
            de = (w >> 11) & 7
            self.vrcp(d, de, t, e, sqrt=fn >= 0x34, low=fn & 1)
            return
        elif fn in (0x32, 0x36):                                  # VRCPH VRSQH
            de = (w >> 11) & 7
            self.accl[:] = self.vte(t, e)
            self.divdp = 1
            self.divin = s16(self.el(self.vr[t], e & 7))
            self.set_el(self.vr[d], de, self.divout & 0xFFFF)
            return
        elif fn == 0x33:                                          # VMOV
            de = (w >> 11) & 7
            v = self.vte(t, e)
            self.set_el(self.vr[d], de, v[de])
            self.accl[:] = v
            return
        else:                                                     # VNOP, VNULL
            return
        self.store_vd(d, out)

    def _mulf_out(self, n, u):
        acch, accm = self.acch, self.accm
        if u:
            return 0 if s16(acch[n]) < 0 else 0xFFFF if (s16(acch[n]) ^ s16(accm[n])) < 0 else accm[n]
        return self.acc_sat(n, 1, 0x8000, 0x7FFF)

    def vrcp(self, d, de, t, e, sqrt, low):
        vt_el = self.el(self.vr[t], e & 7)
        if low and self.divdp:
            inp = s32(((self.divin & 0xFFFF) << 16) | vt_el)
        else:
            inp = s16(vt_el)
        mask = -1 if inp < 0 else 0
        data = inp ^ mask
        if inp > -32768:
            data -= mask
        if data == 0:
            result = 0x7FFFFFFF
        elif inp == -32768:
            result = s32(0xFFFF0000)
        else:
            shift = clz32(data)
            index = ((data << shift) & 0x7FC00000) >> 22
            if sqrt:
                result = self.rsqrt[(index & 0x1FE) | (shift & 1)]
                result = s32((0x10000 | result) << 14)
                result = (result >> ((31 - shift) >> 1)) ^ mask
            else:
                result = self.recip[index]
                result = s32((0x10000 | result) << 14)
                result = (result >> (31 - shift)) ^ mask
        self.divdp = 0
        self.divout = s16(result >> 16)
        self.accl[:] = self.vte(t, e)
        self.set_el(self.vr[d], de, result & 0xFFFF)

    # --- COP2: loads and stores -------------------------------------------------------------------
    def lwc2(self, w, rs, t):
        e = (w >> 7) & 15
        imm = w & 0x7F
        if imm & 0x40:
            imm -= 0x80
        kind = (w >> 11) & 31
        base = self.r[rs]
        vt = self.vr[t]
        db = self.db
        if kind == 0x00:                                          # LBV
            vt[e] = db(base + imm)
        elif kind in (0x01, 0x02, 0x03):                          # LSV LLV LDV
            size = {1: 2, 2: 4, 3: 8}[kind]
            a = base + imm * size
            for off in range(e, min(e + size, 16)):
                vt[off & 15] = db(a); a += 1
        elif kind == 0x04:                                        # LQV
            a = base + imm * 16
            for off in range(e, min(16 + e - (a & 15), 16)):
                vt[off & 15] = db(a); a += 1
        elif kind == 0x05:                                        # LRV
            a = base + imm * 16
            start = 16 - ((a & 15) - e)
            a &= ~15
            for off in range(start, 16):
                vt[off & 15] = db(a); a += 1
        elif kind in (0x06, 0x07):                                # LPV LUV
            a = base + imm * 8
            index = (a & 7) - e
            a &= ~7
            sh = 8 if kind == 0x06 else 7
            for off in range(8):
                self.set_el(vt, off, (db(a + ((index + off) & 15)) << sh) & 0xFFFF)
        elif kind == 0x08:                                        # LHV
            a = base + imm * 16
            index = (a & 7) - e
            a &= ~7
            for off in range(8):
                self.set_el(vt, off, (db(a + ((index + off * 2) & 15)) << 7) & 0xFFFF)
        elif kind == 0x09:                                        # LFV
            a = base + imm * 16
            index = (a & 7) - e
            a &= ~7
            tmp = bytearray(16)
            for off in range(4):
                self.set_el(tmp, off, (db(a + ((index + off * 4) & 15)) << 7) & 0xFFFF)
                self.set_el(tmp, off + 4, (db(a + ((index + off * 4 + 8) & 15)) << 7) & 0xFFFF)
            for off in range(e, min(e + 8, 16)):
                vt[off] = tmp[off]
        elif kind == 0x0B:                                        # LTV
            a = base + imm * 16
            begin = a & ~7
            a = begin + ((e + (a & 8)) & 15)
            vtbase = t & ~7
            vtoff = e >> 1
            for i in range(8):
                reg = self.vr[vtbase + vtoff]
                reg[i * 2] = db(a); a += 1
                if a == begin + 16: a = begin
                reg[i * 2 + 1] = db(a); a += 1
                if a == begin + 16: a = begin
                vtoff = (vtoff + 1) & 7
        # LWV (0x0a) is not on the N64's RSP

    def swc2(self, w, rs, t):
        e = (w >> 7) & 15
        imm = w & 0x7F
        if imm & 0x40:
            imm -= 0x80
        kind = (w >> 11) & 31
        base = self.r[rs]
        vt = self.vr[t]
        wb = self.dwb
        el = self.el
        if kind == 0x00:                                          # SBV
            wb(base + imm, vt[e])
        elif kind in (0x01, 0x02, 0x03):                          # SSV SLV SDV
            size = {1: 2, 2: 4, 3: 8}[kind]
            a = base + imm * size
            for off in range(e, e + size):
                wb(a, vt[off & 15]); a += 1
        elif kind == 0x04:                                        # SQV
            a = base + imm * 16
            for off in range(e, e + (16 - (a & 15))):
                wb(a, vt[off & 15]); a += 1
        elif kind == 0x05:                                        # SRV
            a = base + imm * 16
            end = e + (a & 15)
            b = 16 - (a & 15)
            a &= ~15
            for off in range(e, end):
                wb(a, vt[(off + b) & 15]); a += 1
        elif kind in (0x06, 0x07):                                # SPV SUV
            a = base + imm * 8
            for off in range(e, e + 8):
                lowhalf = (off & 15) < 8
                if (kind == 0x06) == lowhalf:
                    wb(a, vt[(off & 7) << 1])
                else:
                    wb(a, el(vt, off & 7) >> 7)
                a += 1
        elif kind == 0x08:                                        # SHV
            a = base + imm * 16
            index = a & 7
            a &= ~7
            for off in range(8):
                byte = e + off * 2
                v = (vt[byte & 15] << 1) | (vt[(byte + 1) & 15] >> 7)
                wb(a + ((index + off * 2) & 15), v)
        elif kind == 0x09:                                        # SFV
            a = base + imm * 16
            b = a & 7
            a &= ~7
            order = {0: (0, 1, 2, 3), 15: (0, 1, 2, 3), 1: (6, 7, 4, 5), 4: (1, 2, 3, 0), 5: (7, 4, 5, 6),
                     8: (4, 5, 6, 7), 11: (3, 0, 1, 2), 12: (5, 6, 7, 4)}.get(e)
            for k in range(4):
                wb(a + ((b + 4 * k) & 15), (el(vt, order[k]) >> 7) if order else 0)
        elif kind == 0x0A:                                        # SWV
            a = base + imm * 16
            b = a & 7
            a &= ~7
            for off in range(e, e + 16):
                wb(a + (b & 15), vt[off & 15]); b += 1
        elif kind == 0x0B:                                        # STV
            a = base + imm * 16
            start = t & ~7
            element = 16 - (e & ~1)
            b = (a & 7) - (e & ~1)
            a &= ~7
            for off in range(start, start + 8):
                reg = self.vr[off]
                wb(a + (b & 15), reg[element & 15]); b += 1; element += 1
                wb(a + (b & 15), reg[element & 15]); b += 1; element += 1
