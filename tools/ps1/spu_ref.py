"""Reference model of rtl/ps1_spu.v, and the vectors for sim/tb_ps1_spu.v.

    python tools/ps1/spu_ref.py            write sim/spu_test/{ram,script,expect}.hex

The model follows the same rules as the RTL, written out plainly from the spec
(psx-spx, with DuckStation/Mednafen where they differ): ADPCM decode with the
two separate floor shifts, Gaussian interpolation summed then shifted, the
envelope of spec section 7, pitch modulation from the previous voice's output
of the same tick, loop flags / ENDX, Mednafen's noise, and the mix with a clamp
before and after the main volume.

Two things are modelled because the RTL does them, not because hardware does:
  - a voice that has just been keyed on has no block for one tick (the line is
    still being fetched from DDR3): it outputs silence and its pitch counter
    does not move, but its envelope steps;
  - a jump to a block that was not prefetched stalls the same way.
The test never lets a prefetch go stale otherwise.
"""
import os, random

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "sim", "spu_test")
GAUSS_HEX = os.path.join(HERE, "..", "..", "rtl", "ps1_spu_gauss.v")

DEBUG_TICK = set(int(x) for x in os.environ.get("SPU_DEBUG", "").split(",") if x) or None

# the reverb's resampling filter, 39 taps (spec 13.2)
FIR = [-0x0001, 0, 0x0002, 0, -0x000A, 0, 0x0023, 0, -0x0067, 0, 0x010A, 0, -0x0268, 0, 0x0534, 0,
       -0x0B90, 0, 0x2806, 0x4000, 0x2806, 0, -0x0B90, 0, 0x0534, 0, -0x0268, 0, 0x010A, 0, -0x0067, 0,
       0x0023, 0, -0x000A, 0, 0x0002, 0, -0x0001]
assert len(FIR) == 39

POS = [0, 60, 115, 98, 122]
NEG = [0, 0, -52, -55, -60]


def s16(x):
    x &= 0xFFFF
    return x - 0x10000 if x & 0x8000 else x


def clamp16(x):
    return 32767 if x > 32767 else (-32768 if x < -32768 else x)


def load_gauss():
    import re
    g = [0] * 512
    for m in re.finditer(r"rom\[(\d+)\] = 16'h([0-9A-F]{4});", open(GAUSS_HEX).read()):
        g[int(m.group(1))] = s16(int(m.group(2), 16))
    return g


G = load_gauss()


def volume(r):
    r &= 0xFFFF
    if not r & 0x8000:
        return s16((r & 0x7FFF) << 1)
    if r & 0x2000:
        return 0
    if r & 0x1000:
        return -32768
    return 32767


class Voice:
    def __init__(self):
        self.cnt = 0; self.dec = 28; self.h = [0, 0, 0, 0]   # h[0] newest
        self.addr = 0; self.want = 0; self.need = False
        self.ph = 0; self.ec = 0; self.blk = bytes(16); self.env = 0
        self.lsax = 0; self.first = False; self.ign = False
        self.nx = None          # (address, tick it was asked for)
        self.stall = False


class SPU:
    def __init__(self, ram):
        self.ram = bytearray(ram)
        self.v = [Voice() for _ in range(24)]
        self.vol = [0] * 24; self.volr = [0] * 24; self.pitch = [0] * 24; self.ssa = [0] * 24
        self.adsr1 = [0] * 24; self.adsr2 = [0] * 24
        self.spucnt = 0; self.mvoll = 0; self.mvolr = 0
        self.pmon = 0; self.non = 0; self.eon = 0
        self.kon = 0; self.koff = 0; self.endx = 0
        self.lfsr = 0; self.nz_div = 0; self.nz_cnt = 0
        self.rv = [0] * 32; self.evoll = 0; self.evolr = 0
        self.rbase = 0; self.rcur = 0; self.rpos = 0
        self.ds = [[0] * 64, [0] * 64]; self.us = [[0] * 32, [0] * 32]
        self.t = 0

    # --- register writes (16-bit, offset from 1F801C00) ---------------------
    def write(self, off, d):
        d &= 0xFFFF
        if off < 0x180:
            n, k = off >> 4, (off >> 1) & 7
            if k == 0: self.vol[n] = d
            elif k == 1: self.volr[n] = d
            elif k == 2: self.pitch[n] = d
            elif k == 3: self.ssa[n] = d
            elif k == 4: self.adsr1[n] = d
            elif k == 5: self.adsr2[n] = d
            elif k == 6: self.v[n].env = d
            elif k == 7:
                self.v[n].lsax = d
                if self.v[n].ph == 0 or not self.v[n].first: self.v[n].ign = True
            return
        if off == 0x180: self.mvoll = d
        elif off == 0x182: self.mvolr = d
        elif off == 0x188: self.kon |= d
        elif off == 0x18A: self.kon |= (d & 0xFF) << 16
        elif off == 0x18C: self.koff |= d
        elif off == 0x18E: self.koff |= (d & 0xFF) << 16
        elif off == 0x190: self.pmon = (self.pmon & 0xFF0000) | d
        elif off == 0x192: self.pmon = (self.pmon & 0xFFFF) | ((d & 0xFF) << 16)
        elif off == 0x194: self.non = (self.non & 0xFF0000) | d
        elif off == 0x196: self.non = (self.non & 0xFFFF) | ((d & 0xFF) << 16)
        elif off == 0x1AA: self.spucnt = d
        elif off == 0x184: self.evoll = d
        elif off == 0x186: self.evolr = d
        elif off == 0x198: self.eon = (self.eon & 0xFF0000) | d
        elif off == 0x19A: self.eon = (self.eon & 0xFFFF) | ((d & 0xFF) << 16)
        elif off == 0x1A2: self.rbase = (d * 4) & 0x3FFFF; self.rcur = self.rbase
        elif 0x1C0 <= off < 0x200: self.rv[(off - 0x1C0) >> 1] = d

    # --- one ADPCM sample -------------------------------------------------------
    def decode(self, V):
        b = V.blk
        k = V.dec
        nib = (b[2 + k // 2] >> (4 * (k & 1))) & 0xF
        sh = b[0] & 0xF
        if sh > 12: sh = 9
        f = b[0] >> 4
        pos, neg = (POS[f], NEG[f]) if f <= 4 else (0, 0)
        raw = s16(nib << 12) >> sh
        x = raw + ((V.h[0] * pos) >> 6) + ((V.h[1] * neg) >> 6)
        x = clamp16(x)
        V.h = [x] + V.h[:3]
        V.dec += 1

    def block_at(self, a):
        return bytes(self.ram[(a * 8) & 0x7FFF0:((a * 8) & 0x7FFF0) + 16])

    # --- the envelope, one tick ---------------------------------------------------
    def env_tick(self, n, V):
        a1, a2 = self.adsr1[n], self.adsr2[n]
        if V.ph == 1:   r, ex, dec = (a1 >> 8) & 0x7F, (a1 >> 15) & 1, 0
        elif V.ph == 2: r, ex, dec = ((a1 >> 4) & 0xF) << 2, 1, 1
        elif V.ph == 3: r, ex, dec = (a2 >> 6) & 0x7F, (a2 >> 15) & 1, (a2 >> 14) & 1
        else:           r, ex, dec = (a2 & 0x1F) << 2, (a2 >> 5) & 1, 1
        sh, st = r >> 2, r & 3
        base = 7 - st
        if dec: base = ~base
        step = base << (11 - sh) if sh < 11 else base
        inc = 0x8000 >> (sh - 11) if sh > 11 else 0x8000
        s, nn = step, inc
        lvl = V.env & 0xFFFF
        if ex and dec: s = (step * (lvl & 0x7FFF)) >> 15
        if ex and not dec and lvl >= 0x6000:
            if sh < 10: s >>= 2
            elif sh >= 11: nn >>= 2
            else: s >>= 1; nn >>= 1
        allones = (r == 0x7C) if V.ph in (2, 4) else (r == 0x7F)
        if nn == 0 and not allones: nn = 1
        c = (V.ec + nn) & 0xFFFF
        if c & 0x8000:
            V.ec = 0
            lv = lvl + s
            new = (0 if lv < 0 else lv) if dec else (0x7FFF if lv > 0x7FFF else lv)
        else:
            V.ec = c
            new = lvl
        V.env = new
        sl = min(((a1 & 0xF) + 1) * 0x800, 0x7FFF)
        # one transition a tick, judged on the phase the tick started in (DuckStation)
        if V.ph == 1 and new >= 0x7FFF: V.ph = 2; V.ec = 0
        elif V.ph == 2 and new <= sl: V.ph = 3; V.ec = 0
        elif V.ph == 4 and new == 0: V.ph = 0

    # --- the reverb (spec section 13), one channel a tick -------------------------------
    def raddr(self, x, e):
        t = self.rcur + (((x & 0xFFFF) * 4 + e) & 0x3FFFF)
        if t >= 0x40000: t = t - 0x40000 + self.rbase
        return t & 0x3FFFF

    def rread(self, t):
        if t < 0x30000: return 0                  # outside the on-chip region: the RTL reads nothing there
        return s16(self.ram[2 * t] | (self.ram[2 * t + 1] << 8))

    def rwrite(self, t, v):
        if not self.spucnt & 0x80 or t < 0x30000: return
        self.ram[2 * t] = v & 0xFF; self.ram[2 * t + 1] = (v >> 8) & 0xFF

    def reverb(self, inl, inr):
        pos = self.rpos
        self.ds[0][pos] = inl; self.ds[1][pos] = inr
        c = 0 if pos & 1 else 1               # L on odd pos, R on even (Mednafen)
        o = 1 - c
        rv = [s16(x) for x in self.rv]
        acc = 0
        for k in range(39): acc += FIR[k] * self.ds[c][(pos - 38 + k) & 63]
        x = clamp16(acc >> 15)
        R = self.rread; A = self.raddr
        vIIR, vWALL, vAPF1, vAPF2 = rv[2], rv[7], rv[8], rv[9]
        vIN = rv[30 + c]
        dSAME = R(A(self.rv[16 + c], 0)); dDIFF = R(A(self.rv[24 + o], 0))
        mSAMEm = R(A(self.rv[10 + c], -1)); mDIFFm = R(A(self.rv[18 + c], -1))
        comb = [R(A(self.rv[12 + c], 0)), R(A(self.rv[14 + c], 0)), R(A(self.rv[20 + c], 0)), R(A(self.rv[22 + c], 0))]
        fba = R(A((self.rv[26 + c] - self.rv[0]) & 0xFFFF, 0))
        fbb = R(A((self.rv[28 + c] - self.rv[1]) & 0xFFFF, 0))
        def iiasm(v): return (0 if v == -32768 else v * -65536) if vIIR == -32768 else v * (0x8000 - vIIR)
        def neg(v): return 0x7FFF if v == -32768 else -v
        ia = clamp16(((dSAME * vWALL >> 14) + (x * vIN >> 14)) >> 1)
        ib = clamp16(((dDIFF * vWALL >> 14) + (x * vIN >> 14)) >> 1)
        iira = clamp16(((ia * vIIR >> 14) + (iiasm(mSAMEm) >> 14)) >> 1)
        iirb = clamp16(((ib * vIIR >> 14) + (iiasm(mDIFFm) >> 14)) >> 1)
        self.rwrite(A(self.rv[10 + c], 0), iira); self.rwrite(A(self.rv[18 + c], 0), iirb)
        accs = sum((comb[j] * rv[3 + j]) >> 14 for j in range(4))
        mda = clamp16((accs + (fba * neg(vAPF1) >> 14)) >> 1)
        mdb = clamp16(fba + (((mda * vAPF1 >> 14) + (fbb * neg(vAPF2) >> 14)) >> 1))
        wet = clamp16(fbb + (mdb * vAPF2 >> 15))
        self.rwrite(A(self.rv[26 + c], 0), mda); self.rwrite(A(self.rv[28 + c], 0), mdb)
        h = pos >> 1
        self.us[c][h] = wet
        acc = 0
        for k in range(20): acc += FIR[2 * k] * self.us[c][(h - 19 + k) & 31]
        outc = clamp16(acc >> 14)
        outo = self.us[o][(((h - 19) & 31) + 9) & 31]
        if c == 1:                            # after R the work area moves on
            self.rcur += 1
            if self.rcur == 0x40000: self.rcur = self.rbase
        self.rpos = (pos + 1) & 63
        return (outc, outo) if c == 0 else (outo, outc)

    # --- one tick ------------------------------------------------------------------------
    def tick(self):
        t = self.t
        sumL = sumR = 0
        revL = revR = 0
        prev = 0
        for n in range(24):
            V = self.v[n]
            V.stall = False
            if (self.koff >> n) & 1:
                self.koff &= ~(1 << n)
                if V.ph not in (0, 4): V.ph = 4; V.ec = 0
            if (self.kon >> n) & 1:
                self.kon &= ~(1 << n)
                V.want = self.ssa[n] & ~1; V.need = True; V.cnt = 0; V.dec = 28
                V.h = [0, 0, 0, 0]; V.env = 0; V.ec = 0; V.ph = 1
                self.endx &= ~(1 << n); V.ign = False; V.first = True
            if not self.spucnt & 0x8000: V.env = 0; V.ph = 0
            # decode
            while True:
                if V.need and V.dec < 28:
                    self.decode(V)
                elif V.need:
                    if V.nx is not None and V.nx[0] == V.want and V.nx[1] < t:
                        V.blk = self.block_at(V.want); V.addr = V.want; V.need = False; V.dec = 0
                        V.nx = None
                        if (V.blk[1] & 4) and not V.ign: V.lsax = V.want
                    else:
                        if V.nx is None or V.nx[0] != V.want: V.nx = (V.want, t)
                        V.stall = True
                        break
                elif V.dec <= (V.cnt >> 12):
                    self.decode(V)
                else:
                    pa = (V.lsax & ~1) if (V.blk[1] & 1) else (V.addr + 2) & 0xFFFF
                    if V.nx is None or V.nx[0] != pa: V.nx = (pa, t)
                    break
            i = (V.cnt >> 4) & 0xFF
            acc = G[0xFF - i] * V.h[3] + G[0x1FF - i] * V.h[2] + G[0x100 + i] * V.h[1] + G[i] * V.h[0]
            smp = s16(self.lfsr) if (self.non >> n) & 1 else s16(acc >> 15)
            out = (smp * (V.env & 0x7FFF)) >> 15
            if V.ph != 0: self.env_tick(n, V)
            if not V.stall:
                p = self.pitch[n]
                if n > 0 and (self.pmon >> n) & 1:
                    p = ((s16(p) * ((prev + 0x8000) & 0xFFFF)) >> 15) & 0xFFFF
                if p > 0x3FFF: p = 0x3FFF
                c = V.cnt + p
                if c >= 0x1C000:
                    V.cnt = c - 0x1C000; V.need = True; V.first = False
                    if V.blk[1] & 1:
                        self.endx |= 1 << n
                        V.want = V.lsax & ~1
                        if not (V.blk[1] & 2) and not (self.non >> n) & 1: V.env = 0; V.ph = 0
                    else:
                        V.want = (V.addr + 2) & 0xFFFF
                else:
                    V.cnt = c
            L_ = (out * volume(self.vol[n])) >> 15
            R_ = (out * volume(self.volr[n])) >> 15
            sumL += L_; sumR += R_
            if (self.eon >> n) & 1: revL += L_; revR += R_
            if DEBUG_TICK is not None and t in DEBUG_TICK and (self.vol[n] or self.volr[n]):
                print("  model t%d v%-2d out %6d env %04x cnt %05x dec %2d need %d ph %d h %s" % (t, n, out, V.env, V.cnt, V.dec, V.need, V.ph, V.h))
            prev = out
        if not self.spucnt & 0x4000:
            sumL = sumR = revL = revR = 0
        wl, wr = self.reverb(clamp16(revL), clamp16(revR))
        sumL += (wl * s16(self.evoll)) >> 15
        sumR += (wr * s16(self.evolr)) >> 15
        l, r = clamp16(sumL), clamp16(sumR)
        outl = clamp16((l * volume(self.mvoll)) >> 15)
        outr = clamp16((r * volume(self.mvolr)) >> 15)
        # noise
        rf = (self.spucnt >> 8) & 0x3F
        dinc, cinc = (0x8000, 8) if rf >= 0x3C else (2 << (rf >> 2), 4 + (rf & 3))
        if self.nz_div + dinc >= 0x8000:
            self.nz_div = 0
            if self.nz_cnt + cinc >= 8:
                self.nz_cnt = (self.nz_cnt + cinc) & 7
                l_ = self.lfsr
                bit = ((l_ >> 15) ^ (l_ >> 12) ^ (l_ >> 11) ^ (l_ >> 10) ^ 1) & 1
                self.lfsr = ((l_ << 1) | bit) & 0xFFFF
            else:
                self.nz_cnt += cinc
        else:
            self.nz_div += dinc
        self.t += 1
        return outl & 0xFFFF, outr & 0xFFFF


# =============================================================================
# the test: a sample bank, a register script, and what should come out
# =============================================================================
def make_blocks(rng, n, flags_last, start_at=None):
    out = bytearray()
    for k in range(n):
        sh = rng.randrange(0, 13)
        f = rng.randrange(0, 5)
        fl = 0
        if start_at is not None and k == start_at: fl |= 4
        if k == n - 1: fl |= flags_last
        body = bytes(rng.randrange(256) for _ in range(14))
        out += bytes([(f << 4) | sh, fl]) + body
    return out


def main():
    rng = random.Random(1234)
    ram = bytearray(0x80000)
    # sample A at 0x1000: 6 blocks, loop from block 2, end+repeat on the last
    A = 0x1000; a = make_blocks(rng, 6, 3, start_at=2); ram[A:A + len(a)] = a
    # sample B at 0x2000: 3 blocks, end without repeat (plays once, then mutes)
    B = 0x2000; b = make_blocks(rng, 3, 1); ram[B:B + len(b)] = b
    # sample C at 0x3000: 4 blocks looping on itself from the first
    C = 0x3000; c = make_blocks(rng, 4, 3, start_at=0); ram[C:C + len(c)] = c
    # silence with start+end+repeat at 0x4000, the conventional "rest" block
    ram[0x4000:0x4010] = bytes([0, 7]) + bytes(14)
    upload = ram[0x1000:0x4010]

    # the script: (tick, offset, value). Tick 0 = before the first tick.
    S = []
    def w(t, off, d): S.append((t, off, d & 0xFFFF))
    w(0, 0x1AA, 0xC000 | (0x0B << 8))      # SPU on, unmuted, some noise rate
    w(0, 0x180, 0x3FFF); w(0, 0x182, 0x3000)
    def voice(t, n, ssa, pitch, vl, vr, a1, a2):
        base = n * 16
        w(t, base + 0, vl); w(t, base + 2, vr); w(t, base + 4, pitch); w(t, base + 6, ssa)
        w(t, base + 8, a1); w(t, base + 10, a2)
    # attack linear fast, decay, sustain exp decrease, release linear
    voice(0, 0, A // 8, 0x1000, 0x3FFF, 0x2000, 0x2F1A, 0x9FC8)
    # higher pitch (several samples a tick), exponential attack
    voice(0, 1, B // 8, 0x2B85, 0x2000, 0x3FFF, 0x9F2F, 0x5FA2)
    # pitch-modulated by voice 1
    voice(0, 2, C // 8, 0x0C00, 0x3000, 0x3000, 0x3F0F, 0x1FC5)
    w(0, 0x190, 1 << 2)
    # a noise voice, quiet
    voice(0, 3, 0x4000 // 8, 0x1000, 0x0800, 0x0400, 0x7F00, 0x1FC0)
    w(0, 0x194, 1 << 3)
    # a slow one, near max pitch, sweep volume (taken to its target)
    voice(0, 5, C // 8, 0x3FFF, 0xC000 | 0x0041, 0x1000, 0x0A0F, 0x0F80)
    # a LSAX written before KON: its loop start flag must not override (block 0 of A has none)
    w(0, 5 * 16 + 14, 0x4000 // 8)
    # reverb: a room-sized area at the top of RAM, on voices 0 and 2
    room = [0x007D, 0x005B, 0x6D80, 0x54B8, 0xBED0, 0x0000, 0x0000, 0xBA80, 0x5800, 0x5300,
            0x04D6, 0x0333, 0x03F0, 0x0227, 0x0374, 0x01EF, 0x0334, 0x01B5, 0x0000, 0x0000,
            0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x01B4, 0x0136, 0x00B8, 0x005C,
            0x8000, 0x8000]
    # The preset's delays run to ~0.2 s, longer than the test, so most taps would
    # only ever read the empty area. Shrunk eightfold, the feedback paths all work.
    for k, d in enumerate(room):
        is_addr = k in (0, 1) or 10 <= k <= 29
        w(0, 0x1C0 + 2 * k, (d // 8) if is_addr else d)
    w(0, 0x1A2, (0x80000 - 0x26C0) // 8)
    w(0, 0x184, 0x3000); w(0, 0x186, 0x2C00)
    w(0, 0x198, (1 << 0) | (1 << 2))
    w(0, 0x1AA, 0xC080 | (0x0B << 8))     # and the reverb master enable
    w(2, 0x188, (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 5))
    w(400, 0x18C, 1 << 0)                  # voice 0 released
    w(700, 0x188, 1 << 0)                  # and keyed on again
    w(900, 0x18C, 1 << 5)
    w(1200, 0x1AA, 0x8080 | (0x0B << 8))   # muted for a while (the reverb tail still sounds)
    w(1300, 0x1AA, 0xC080 | (0x21 << 8))   # back, another noise rate
    w(1800, 0x1AA, 0xC000 | (0x21 << 8))   # reverb writes off: the area stops changing
    w(1500, 0x188, 1 << 1)                 # voice 1 again (it had muted itself at the end of B)
    TICKS = 2500

    spu = SPU(ram)
    expect = []
    si = 0
    S.sort(key=lambda x: x[0])
    for t in range(TICKS + 1):
        while si < len(S) and S[si][0] == t:
            spu.write(S[si][1], S[si][2]); si += 1
        if t == TICKS: break
        l, r = spu.tick()
        expect.append((r << 16) | l)

    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "ram.hex"), "w") as f:
        f.write("// the sample bank uploaded by DMA to SPU RAM 0x1000, 32-bit words\n")
        for k in range(0, len(upload), 4):
            f.write("%08X\n" % int.from_bytes(upload[k:k + 4], "little"))
    with open(os.path.join(OUT, "script.hex"), "w") as f:
        f.write("// {tick[15:0], offset[15:0], value[15:0]}\n")
        for t, off, d in S:
            f.write("%04X%04X%04X\n" % (t, off, d))
    with open(os.path.join(OUT, "expect.hex"), "w") as f:
        f.write("// {right, left} per tick\n")
        for e in expect:
            f.write("%08X\n" % e)
    with open(os.path.join(OUT, "endx.hex"), "w") as f:
        f.write("// ENDX after the last tick\n%08X\n" % spu.endx)
    nz = sum(1 for e in expect if e)
    print("words %d, script %d, ticks %d, non-silent %d, endx %06x"
          % (len(upload) // 4, len(S), len(expect), nz, spu.endx))


if __name__ == "__main__":
    main()
