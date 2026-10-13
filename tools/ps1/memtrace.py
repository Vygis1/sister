"""memtrace.py - a real game's memory accesses, for choosing the processor's caches by measurement.

Runs the R3000's code from a DuckStation savestate (RAM, registers, scratchpad) in a small
interpreter, with the hardware around it reduced to what keeps the game's own loop turning:
VBlank and timer interrupts, DMA done at once (its reads and writes traced: the GPU's linked
lists, the ordering-table clear), the GPU always ready, the CD idle, the pads absent. What it
writes is every instruction fetch, load and store the processor makes, and every word the DMA
moves, as one stream:

    python tools/ps1/memtrace.py SAVESTATE OUT.bin [VBLANKS]

OUT.bin is little-endian u32s: bits 31:29 the kind (0 fetch, 1 load, 2 store, 3 DMA read,
4 DMA write, 7 a VBlank), 28:0 the physical address. tools/ps1/cachemodel.py replays it
through the core's cache hierarchy and alternatives to it.

Not an exact machine: the GPU never makes the processor wait, the CD never delivers, and the
GTE starts from zero (the game reloads its matrices every frame). The point is the SHAPE of the
memory traffic -- which code and data the game touches each frame, and in what order -- which
those do not change.
"""
import struct, sys, os, array, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gte as gtemod

M = 0xFFFFFFFF
def sx16(v): return (v & 0xFFFF) - 0x10000 if v & 0x8000 else v & 0xFFFF
def sx8(v):  return (v & 0xFF) - 0x100 if v & 0x80 else v & 0xFF


def load_state(path):
    import zstandard
    d = open(path, 'rb').read()
    i = d.find(b'\x28\xb5\x2f\xfd', 0x100)
    frames = []
    while i >= 0:
        frames.append(i); i = d.find(b'\x28\xb5\x2f\xfd', i + 4)
    s = max((zstandard.ZstdDecompressor().decompressobj().decompress(d[f:]) for f in frames), key=len)
    # the CPU section: "CPU" at 0x2b, its data at 0x2e (see the notes at the bottom)
    w = struct.unpack_from('<60I', s, 0x2e)
    regs = list(w[4:36])                 # r0..r31
    hi, lo = w[36], w[37]
    sr, cause, epc = w[48], w[49], w[46]
    cur_pc = w[38]                       # regs.pc: the game is at a function's entry, an interrupt pending
    # main RAM: the Bus section, found by the BIOS's exception handler at 0x80
    pat = struct.pack('<II', 0x3c1a0000, 0x275a0c80)
    ram_at = s.find(pat, 0x1a1b) - 0x80
    ram = bytearray(s[ram_at:ram_at + 0x200000])
    scratch = bytearray(s[0x11a:0x11a + 0x400])
    g = struct.unpack_from('<64I', s, 0x51a)       # the GTE: 32 data, 32 control (ZSF3/ZSF4 0x155/0x100 at its end)
    return dict(regs=regs, hi=hi, lo=lo, sr=sr, cause=cause, epc=epc, pc=cur_pc, ram=ram, scratch=scratch, gte=g)


class Machine:
    def __init__(self, st, bios):
        self.r = [x & M for x in st['regs']]; self.r[0] = 0
        self.hi, self.lo = st['hi'], st['lo']
        self.ram = st['ram']; self.scratch = st['scratch']; self.under = bytearray(0x10000)
        self.bios = bytearray(bios)
        self.sr = st['sr']; self.cause = st['cause'] & ~0x7C; self.epc = st['epc']
        self.cop0 = [0] * 32
        self.pc = st['pc']; self.npc = (self.pc + 4) & M
        self.istat = 0x1; self.imask = 0x0D          # the VBlank the state was saved on: pending
        self.io = {}
        self.dma = [[0, 0, 0] for _ in range(7)]; self.dpcr = 0x07654321; self.dicr = 0
        self.tm = [[0, 0, 0, 0] for _ in range(3)]; self.tlast = [0, 0, 0]
        self.tm[1][1] = 0x100                        # (timer 1 on HBLANK, as games set it before this state was saved)  # counter base cycle, mode, target, value at base
        self.gte = gtemod.GTE()
        for i in range(32): self.gte.d[i] = st['gte'][i]; self.gte.c[i] = st['gte'][32 + i]
        self.cycles = 0
        self.tr = array.array('I')
        self.gpustat_odd = 0
        self.ld = None                               # (reg, value) of a load in its delay slot
        self.in_bd = False

    # ---------------------------------------------------------------- memory
    def phys(self, a):
        return a & 0x1FFFFFFF if a < 0xC0000000 else a

    def read(self, a, n, kind=1):
        p = self.phys(a)
        if p < 0x800000:
            p &= 0x1FFFFF
            self.tr.append((kind << 29) | p)
            if n == 4: return struct.unpack_from('<I', self.ram, p)[0]
            if n == 2: return struct.unpack_from('<H', self.ram, p)[0]
            return self.ram[p]
        if 0x1F7F0000 <= p < 0x1F800000:
            o = p - 0x1F7F0000
            if n == 4: return struct.unpack_from('<I', self.under, o)[0]
            if n == 2: return struct.unpack_from('<H', self.under, o)[0]
            return self.under[o]
        if 0x1F800000 <= p < 0x1F800400:
            o = p - 0x1F800000
            if n == 4: return struct.unpack_from('<I', self.scratch, o)[0]
            if n == 2: return struct.unpack_from('<H', self.scratch, o)[0]
            return self.scratch[o]
        if 0x1FC00000 <= p < 0x1FC80000:
            o = p - 0x1FC00000
            self.tr.append((kind << 29) | p)
            if n == 4: return struct.unpack_from('<I', self.bios, o)[0]
            if n == 2: return struct.unpack_from('<H', self.bios, o)[0]
            return self.bios[o]
        return self.ioread(p, n)

    def write(self, a, v, n):
        if self.sr & 0x10000: return                 # the cache isolated: the BIOS flushing it
        p = self.phys(a)
        if p < 0x800000:
            p &= 0x1FFFFF
            self.tr.append((2 << 29) | p)
            if n == 4: struct.pack_into('<I', self.ram, p, v & M)
            elif n == 2: struct.pack_into('<H', self.ram, p, v & 0xFFFF)
            else: self.ram[p] = v & 0xFF
            return
        if 0x1F7F0000 <= p < 0x1F800000:
            o = p - 0x1F7F0000
            if n == 4: struct.pack_into('<I', self.under, o, v & M)
            elif n == 2: struct.pack_into('<H', self.under, o, v & 0xFFFF)
            else: self.under[o] = v & 0xFF
            return
        if 0x1F800000 <= p < 0x1F800400:
            o = p - 0x1F800000
            if n == 4: struct.pack_into('<I', self.scratch, o, v & M)
            elif n == 2: struct.pack_into('<H', self.scratch, o, v & 0xFFFF)
            else: self.scratch[o] = v & 0xFF
            return
        if 0x1FC00000 <= p < 0x1FC80000 or p == 0xFFFE0130: return
        self.iowrite(p, v, n)

    # ---------------------------------------------------------------- the hardware, reduced
    def timer_val(self, n):
        base, mode, target, v0 = self.tm[n]
        src = (mode >> 8) & 3
        # the clock each counts (an instruction taken as two system clocks): timer 0 the dot
        # clock or the system's, timer 1 HBLANKs (a line is ~2150 clocks) or the system's,
        # timer 2 the system's or an eighth of it -- a game reads one twice until it agrees
        div = (5 if src & 1 else 1) if n == 0 else (2150 if src & 1 else 1) if n == 1 else (8 if src & 2 else 1)
        span = (target + 1) if (mode & 0x8) and target else 0x10000
        return (v0 + (2 * (self.cycles - base)) // div) % span

    def ioread(self, p, n):
        if p == 0x1F801070: return self.istat
        if p == 0x1F801074: return self.imask
        if 0x1F801080 <= p < 0x1F8010F0:
            ch, r = (p - 0x1F801080) >> 4, (p >> 2) & 3
            return self.dma[ch][r] if r < 3 else 0
        if p == 0x1F8010F0: return self.dpcr
        if p == 0x1F8010F4: return self.dicr
        if p == 0x1F801810: return 0
        if p == 0x1F801814:
            self.gpustat_odd ^= 1
            return 0x1C802000 | (self.gpustat_odd << 31)
        if 0x1F801100 <= p < 0x1F801130:
            t, r = (p - 0x1F801100) >> 4, (p >> 2) & 3
            if r == 0: return self.timer_val(t)
            if r == 1: return self.tm[t][1] | 0x1800
            if r == 2: return self.tm[t][2]
            return 0
        if p == 0x1F801800: return 0x18 | (self.io.get(p, 0) & 3)
        if 0x1F801801 <= p <= 0x1F801803: return 0
        if p == 0x1F801044: return 0x0007                                  # JOY_STAT: ready, no pad
        if p == 0x1F801040: return 0xFF
        if p == 0x1F801DAE: return self.io.get(0x1F801DAA, 0) & 0x3F       # SPUSTAT
        return self.io.get(p & ~1 if n == 2 else p, 0)

    def iowrite(self, p, v, n):
        if p == 0x1F801070: self.istat &= v; return
        if p == 0x1F801074: self.imask = v & 0x7FF; return
        if 0x1F801080 <= p < 0x1F8010F0:
            ch, r = (p - 0x1F801080) >> 4, (p >> 2) & 3
            if r < 3:
                self.dma[ch][r] = v & M
                if r == 2 and (v & 0x01000000): self.run_dma(ch)
            return
        if p == 0x1F8010F0: self.dpcr = v; return
        if p == 0x1F8010F4:
            self.dicr = (self.dicr & 0x7F000000 & ~(v & 0x7F000000)) | (v & 0x00FF803F); self.dicr_update(); return
        if 0x1F801100 <= p < 0x1F801130:
            t, r = (p - 0x1F801100) >> 4, (p >> 2) & 3
            if r == 0: self.tm[t][0] = self.cycles; self.tm[t][3] = v & 0xFFFF
            elif r == 1: self.tm[t][1] = v & 0x3FF; self.tm[t][0] = self.cycles; self.tm[t][3] = 0
            elif r == 2: self.tm[t][2] = v & 0xFFFF
            return
        self.io[p] = v

    def dicr_update(self):
        f = (self.dicr >> 24) & 0x7F; en = (self.dicr >> 16) & 0x7F
        if (self.dicr & 0x8000) or ((self.dicr & 0x800000) and (f & en)):
            if not (self.dicr & 0x80000000): self.istat |= 0x8
            self.dicr |= 0x80000000
        else:
            self.dicr &= 0x7FFFFFFF

    def run_dma(self, ch):
        madr, bcr, chcr = self.dma[ch]
        a = madr & 0x1FFFFC
        to_ram = not (chcr & 1)
        mode = (chcr >> 9) & 3
        tr = self.tr
        if ch == 6:                                  # the ordering-table clear: backwards
            n = bcr & 0xFFFF or 0x10000
            for k in range(n):
                v = 0xFFFFFF if k == n - 1 else (a - 4) & 0x1FFFFF
                struct.pack_into('<I', self.ram, a, v); tr.append((4 << 29) | a)
                a = (a - 4) & 0x1FFFFC
        elif mode == 2:                              # a linked list (the GPU's)
            guard = 0
            while guard < 200000:
                hdr = struct.unpack_from('<I', self.ram, a)[0]; tr.append((3 << 29) | a)
                for k in range(hdr >> 24): tr.append((3 << 29) | ((a + 4 + 4 * k) & 0x1FFFFC))
                if hdr & 0x800000: break
                a = hdr & 0x1FFFFC; guard += 1
        else:
            n = ((bcr & 0xFFFF) or 0x10000) * (((bcr >> 16) or 1) if mode == 1 else 1)
            for k in range(min(n, 0x40000)):
                tr.append(((4 if to_ram else 3) << 29) | ((a + 4 * k) & 0x1FFFFC))
        self.dma[ch][2] &= ~0x11000000
        self.dicr |= (1 << (24 + ch)) if (self.dicr >> (16 + ch)) & 1 else 0
        self.dicr_update()

    # ---------------------------------------------------------------- the processor
    def exception(self, code, cur, bd):
        self.cause = (self.cause & ~0x8000007C) | (code << 2) | (0x80000000 if bd else 0)
        self.epc = (cur - 4) & M if bd else cur
        self.sr = (self.sr & ~0x3F) | ((self.sr << 2) & 0x3F)
        self.pc = 0x80000080 if not (self.sr & 0x400000) else 0xBFC00180
        self.npc = (self.pc + 4) & M

    def run(self, vblanks, ipv, maxi=None, log=None):
        r = self.r; tr = self.tr; gte = self.gte
        nextvb = self.cycles + ipv; vb = 0; pcs = collections.Counter()
        while vb < vblanks and (maxi is None or self.cycles < maxi):
            if self.cycles >= nextvb:
                self.istat |= 1; nextvb += ipv; vb += 1; tr.append(7 << 29)
            # timers reaching their target, roughly: an interrupt when one wraps at it
            if (self.cycles & 0x3FF) == 0:
                for t in range(3):
                    mode = self.tm[t][1]
                    if mode & 0x10 and mode & 0x8 and self.tm[t][2]:
                        v = self.timer_val(t)
                        if v < self.tlast[t]: self.istat |= (0x10 << t)
                        self.tlast[t] = v
            cur = self.pc
            bd = self.in_bd
            self.cause = (self.cause & ~0x400) | (0x400 if (self.istat & self.imask) else 0)
            if (self.sr & 1) and (self.sr & self.cause & 0xFF00):
                self.exception(0, cur, bd); self.in_bd = False
                if self.ld: r[self.ld[0]] = self.ld[1]; self.ld = None
                continue
            ins = self.read(cur, 4, 0)
            if log is not None: log.append((cur, ins, self.ld))
            self.cycles += 1
            if (self.cycles & 0xFFF) == 0: pcs[cur & ~0xFF] += 1
            self.pc = self.npc; self.npc = (self.npc + 4) & M
            self.in_bd = False
            pend = self.ld; self.ld = None; wrote = -1
            op = ins >> 26; rs = (ins >> 21) & 31; rt = (ins >> 16) & 31
            imm = ins & 0xFFFF; simm = imm - 0x10000 if imm & 0x8000 else imm
            if op == 0:
                rd = (ins >> 11) & 31; fn = ins & 63; sa = (ins >> 6) & 31
                a, b = r[rs], r[rt]; res = None
                if fn == 0: res = (b << sa) & M
                elif fn == 2: res = b >> sa
                elif fn == 3: res = ((b - (1 << 32) if b & 0x80000000 else b) >> sa) & M
                elif fn == 4: res = (b << (a & 31)) & M
                elif fn == 6: res = b >> (a & 31)
                elif fn == 7: res = ((b - (1 << 32) if b & 0x80000000 else b) >> (a & 31)) & M
                elif fn == 8: self.npc = a; self.in_bd = True
                elif fn == 9: res = (cur + 8) & M; self.npc = a; self.in_bd = True
                elif fn == 12: self.exception(8, cur, bd)
                elif fn == 13: self.exception(9, cur, bd)
                elif fn == 16: res = self.hi
                elif fn == 17: self.hi = a
                elif fn == 18: res = self.lo
                elif fn == 19: self.lo = a
                elif fn == 24:
                    sa_ = a - (1 << 32) if a & 0x80000000 else a; sb_ = b - (1 << 32) if b & 0x80000000 else b
                    p = sa_ * sb_; self.lo = p & M; self.hi = (p >> 32) & M
                elif fn == 25: p = a * b; self.lo = p & M; self.hi = (p >> 32) & M
                elif fn == 26:
                    sa_ = a - (1 << 32) if a & 0x80000000 else a; sb_ = b - (1 << 32) if b & 0x80000000 else b
                    if sb_ == 0: self.lo = 1 if sa_ < 0 else M; self.hi = a
                    else:
                        q = abs(sa_) // abs(sb_); q = -q if (sa_ < 0) != (sb_ < 0) else q
                        self.lo = q & M; self.hi = (sa_ - q * sb_) & M
                elif fn == 27:
                    if b == 0: self.lo = M; self.hi = a
                    else: self.lo = a // b; self.hi = a % b
                elif fn in (32, 33): res = (a + b) & M
                elif fn in (34, 35): res = (a - b) & M
                elif fn == 36: res = a & b
                elif fn == 37: res = a | b
                elif fn == 38: res = a ^ b
                elif fn == 39: res = ~(a | b) & M
                elif fn == 42: res = 1 if (a ^ 0x80000000) < (b ^ 0x80000000) else 0
                elif fn == 43: res = 1 if a < b else 0
                if res is not None and rd: r[rd] = res; wrote = rd
            elif op == 1:
                a = r[rs]; neg = a & 0x80000000
                take = (not neg) if (rt & 1) else bool(neg)
                if (rt & 0x1E) == 0x10: r[31] = (cur + 8) & M; wrote = 31
                if take: self.npc = (self.pc + (simm << 2)) & M
                self.in_bd = True
            elif op == 2 or op == 3:
                if op == 3: r[31] = (cur + 8) & M; wrote = 31
                self.npc = (self.pc & 0xF0000000) | ((ins & 0x3FFFFFF) << 2); self.in_bd = True
            elif 4 <= op <= 7:
                a, b = r[rs], r[rt]
                if op == 4: take = a == b
                elif op == 5: take = a != b
                elif op == 6: take = a == 0 or a & 0x80000000
                else: take = a != 0 and not (a & 0x80000000)
                if take: self.npc = (self.pc + (simm << 2)) & M
                self.in_bd = True
            elif 8 <= op <= 15:
                a = r[rs]
                if op in (8, 9): res = (a + simm) & M
                elif op == 10: res = 1 if (a ^ 0x80000000) < ((simm & M) ^ 0x80000000) else 0
                elif op == 11: res = 1 if a < (simm & M) else 0
                elif op == 12: res = a & imm
                elif op == 13: res = a | imm
                elif op == 14: res = a ^ imm
                else: res = imm << 16
                if rt: r[rt] = res; wrote = rt
            elif op == 16:                            # COP0
                if rs == 0:   self.ld = (rt, self.sr if ((ins >> 11) & 31) == 12 else self.cause if ((ins >> 11) & 31) == 13 else self.epc if ((ins >> 11) & 31) == 14 else 2 if ((ins >> 11) & 31) == 15 else self.cop0[(ins >> 11) & 31])
                elif rs == 4:
                    rd = (ins >> 11) & 31
                    if rd == 12: self.sr = r[rt]
                    elif rd == 13: self.cause = (self.cause & ~0x300) | (r[rt] & 0x300)
                    else: self.cop0[rd] = r[rt]
                elif rs == 16 and (ins & 63) == 16: self.sr = (self.sr & ~0x0F) | ((self.sr >> 2) & 0x0F)
            elif op == 18:                            # COP2
                if rs == 0:   self.ld = (rt, gte.read_data((ins >> 11) & 31) & M)
                elif rs == 2: self.ld = (rt, gte.read_ctrl((ins >> 11) & 31) & M)
                elif rs == 4: gte.write_data((ins >> 11) & 31, r[rt])
                elif rs == 6: gte.write_ctrl((ins >> 11) & 31, r[rt])
                elif rs & 0x10:
                    try: gte.op(ins & 0x1FFFFFF)
                    except Exception: pass
            elif 32 <= op <= 38:                      # loads
                ad = (r[rs] + simm) & M
                if op == 32: v = sx8(self.read(ad, 1)) & M
                elif op == 33: v = sx16(self.read(ad & ~1, 2)) & M
                elif op == 35: v = self.read(ad & ~3, 4)
                elif op == 36: v = self.read(ad, 1)
                elif op == 37: v = self.read(ad & ~1, 2)
                else:                                 # LWL / LWR: merge into the register as the load delay leaves it
                    w = self.read(ad & ~3, 4); old = pend[1] if pend and pend[0] == rt else r[rt]
                    sh = ad & 3
                    if op == 34: v = ((old & (0x00FFFFFF >> (sh * 8))) | (w << (24 - sh * 8))) & M
                    else: v = ((old & ((0xFFFFFF00 << (24 - sh * 8)) & M)) | (w >> (sh * 8))) & M
                if rt: self.ld = (rt, v)
            elif 40 <= op <= 46:                      # stores
                ad = (r[rs] + simm) & M; v = r[rt]
                if op == 40: self.write(ad, v, 1)
                elif op == 41: self.write(ad & ~1, v, 2)
                elif op == 43: self.write(ad & ~3, v, 4)
                else:
                    w = self.read(ad & ~3, 4, 1); sh = ad & 3
                    if op == 42: nv = (w & ((0xFFFFFF00 << (sh * 8)) & M)) | (v >> (24 - sh * 8))
                    else: nv = (w & (0x00FFFFFF >> (24 - sh * 8))) | ((v << (sh * 8)) & M)
                    self.write(ad & ~3, nv & M, 4)
            elif op == 50:                            # LWC2
                ad = (r[rs] + simm) & M; gte.write_data(rt, self.read(ad & ~3, 4))
            elif op == 58:                            # SWC2
                ad = (r[rs] + simm) & M; self.write(ad & ~3, gte.read_data(rt) & M, 4)
            if pend and pend[0] != wrote:
                if pend[0]: r[pend[0]] = pend[1]
            r[0] = 0
        return pcs


def main():
    st = load_state(sys.argv[1])
    biosp = os.path.join(os.path.expanduser('~'), 'Documents', 'DuckStation', 'bios', 'scph1001.bin')
    m = Machine(st, open(biosp, 'rb').read())
    vbl = int(sys.argv[3]) if len(sys.argv) > 3 else 30
    ipv = int(sys.argv[4]) if len(sys.argv) > 4 else 330000
    import time
    t0 = time.time()
    print('start pc %08x sr %08x sp %08x' % (m.pc, m.sr, m.r[29]))
    pcs = m.run(vbl, ipv)
    dt = time.time() - t0
    print('%d instructions in %.1f s, %d trace entries' % (m.cycles, dt, len(m.tr)))
    for pc, n in pcs.most_common(12): print('  %08x %5.1f%%' % (pc, 100.0 * n / max(1, sum(pcs.values()))))
    with open(sys.argv[2], 'wb') as f: m.tr.tofile(f)

if __name__ == '__main__':
    main()

# State layout (DuckStation savestate version 85, the second zstd frame decompressed):
# 0x27 "\3\0\0\0CPU", data from 0x2e: u32 [0..3] ticks etc., [4..35] r0..r31, [36] hi, [37] lo,
# [38] pc?, [39] npc?, [40..46] BPC BDA TAR BadVaddr BDAM BPCM EPC, [47] PRID, [48] SR,
# [49] CAUSE, [50] DCIC, [51] next instruction, [52] current instruction... -- inferred from the
# values; the scratchpad at 0x11a (the game's scratch stack tops out at 0x3e0, return addresses
# there), the GTE's 64 registers at 0x51a, the I-cache tags at 0x61a and data at 0xa1a (the BIOS handler at 0x80 lines up), main RAM in the
# Bus section, located by that handler.
