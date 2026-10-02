"""The N64 in Python: the reference the RTL is checked against.

    python tools/n64model.py ROM.N64 [--steps N] [--png out.png] [--trace]

A VR4300 instruction-set model (MIPS III, 64-bit, big-endian) with COP0, the
TLB and the exception model, and as much of the rest of the machine as a
CPU test needs: RDRAM, the cartridge and PI DMA, SP memory, MI interrupts,
and the VI's registers -- whose framebuffer is written out as a PNG, which is
how krom's test ROMs report PASS and FAIL.

Every instruction follows ares's interpreter (ISC licence,
ares/n64/cpu/interpreter-ipu.cpp and interpreter-scc.cpp), including the
places where the chip is odd:
  - MULT multiplies rs as 64 bits by rt as 35 bits; DIV divides rs as 32
    bits sign-extended by rt as 64 bits (results differ from the textbook
    only when an operand is not a sign-extended 32-bit value);
  - SRA and SRAV shift the whole 64-bit register, then sign-extend the low
    word;
  - LWR sign-extends only when it loads the whole word;
  - the branch-likely-and-link instructions write RA whether or not they
    branch, and a likely branch not taken skips its delay slot.

The boot needs no PIF ROM and runs no Nintendo boot code: the first
megabyte of the game is copied to RDRAM at its entry point and the values
the boot code leaves in low memory are filled in, as many emulators do.

Speed: around a quarter of a million instructions a second. Enough for test
ROMs; it is a reference, not a player.
"""
import struct
import sys
import zlib

M64 = (1 << 64) - 1
M32 = 0xFFFFFFFF


def sx32(v):
    """the low 32 bits, sign-extended to 64 (as an unsigned 64-bit value)"""
    v &= M32
    return v | 0xFFFFFFFF00000000 if v & 0x80000000 else v


def sx16(v):
    v &= 0xFFFF
    return v | 0xFFFFFFFFFFFF0000 if v & 0x8000 else v


def sx8(v):
    v &= 0xFF
    return v | 0xFFFFFFFFFFFFFF00 if v & 0x80 else v


def s64(v):
    v &= M64
    return v - (1 << 64) if v & (1 << 63) else v


def s32(v):
    v &= M32
    return v - (1 << 32) if v & 0x80000000 else v


class Exc(Exception):
    """An exception the instruction raised: unwinds to the step loop."""
    def __init__(self, code, ce=0, tlb_miss=False):
        self.code, self.ce, self.tlb_miss = code, ce, tlb_miss


# exception codes
INT, MOD, TLBL, TLBS, ADEL, ADES, IBE, DBE, SYS, BP, RI, CPU_, OV, TR, FPE = 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 15


class TLBEntry:
    def __init__(self):
        self.page_mask = 0
        self.vpn = 0          # virtual address bits 13..39, as an address
        self.region = 0
        self.asid = 0
        self.gl = [0, 0]      # EntryLo0.G, EntryLo1.G
        self.g = 0            # both: the entry ignores the ASID
        self.pfn = [0, 0]     # physical addresses
        self.c = [0, 0]
        self.d = [0, 0]
        self.v = [0, 0]
        self.sync()

    def sync(self):
        pm = self.page_mask & (0b101010101010 << 13)
        pm |= pm >> 1
        self.page_mask = pm
        self.mask_hi = ~(pm | 0x1FFF) & ((1 << 40) - 1)
        self.mask_lo = (pm | 0x1FFF) >> 1
        self.select = self.mask_lo + 1
        self.vpn &= self.mask_hi
        self.pfn = [p & M32 for p in self.pfn]
        self.g = self.gl[0] & self.gl[1]
        self.gl = [self.g, self.g]

    def copy(self):
        e = TLBEntry()
        e.__dict__.update({k: (list(v) if isinstance(v, list) else v) for k, v in self.__dict__.items()})
        return e


class VR4300:
    def __init__(self, bus):
        self.bus = bus
        self.r = [0] * 32
        self.hi = self.lo = 0
        self.pc = 0           # the instruction being executed
        self.npc = 0          # the one after it
        self.delay = False    # this instruction is in a delay slot
        self.next_delay = False
        self.llbit = 0
        self.ll = 0
        # COP0
        self.index = 0
        self.probe_fail = 0
        self.entry = TLBEntry()   # EntryHi / EntryLo0/1 / PageMask staging
        self.context_ptebase = 0
        self.context_bad = 0x7FFFF             # power-on: BadVPN2 all ones (Context reads 007FFFF0)
        self.xcontext_ptebase = 0
        self.xcontext_bad = 0
        self.xcontext_region = 0
        self.wired = 0
        self.badvaddr = M64                    # power-on: all ones
        self.count = 0        # in half-cycles: Count = count >> 1
        self.compare = 0      # likewise
        self.status = 0x34000000 | (1 << 22) | (1 << 2)   # reset: BEV, ERL; IPL3 leaves 0x34000000
        # power-on Cause: BD set, CE 3, ExcCode 31 (B000007C); IPL3 writes only IP0/IP1
        self.cause = 0xB000007C
        self.epc = M64
        self.errorepc = M64
        self.config = 0x7006E463
        self.taglo = 0
        self.latch = 0
        # Power-on TLB contents are garbage that matches nothing a program uses
        # (krom's TLB tests take a refill miss at address 0x10 with no setup). An
        # all-zero entry would match page 0 and raise "invalid" instead; so each
        # entry starts where libultra's osUnmapTLBAll puts it, on a KSEG0 page,
        # which never goes through the TLB.
        self.tlb = [TLBEntry() for _ in range(32)]
        for i, e in enumerate(self.tlb):
            e.vpn = 0x80000000 + i * 0x2000
            e.sync()
        self.random_state = 31
        self.instructions = 0
        self.decoded = {}

    # --- mode -----------------------------------------------------------------------
    def kernel(self):
        return (self.status & 0x6) or ((self.status >> 3) & 3) == 0

    def bits64(self):
        if self.status & 0x6 or ((self.status >> 3) & 3) == 0:
            return (self.status >> 7) & 1
        if ((self.status >> 3) & 3) == 1:
            return (self.status >> 6) & 1
        return (self.status >> 5) & 1

    # --- addresses ------------------------------------------------------------------
    def address_exception(self, vaddr):
        self.badvaddr = vaddr & M64
        self.entry.vpn = (vaddr >> 13 << 13) & ((1 << 40) - 1)
        self.entry.region = (vaddr >> 62) & 3
        self.context_bad = (vaddr >> 13) & 0x7FFFF
        self.xcontext_bad = (vaddr >> 13) & 0x7FFFFFF
        self.xcontext_region = (vaddr >> 62) & 3

    def translate(self, vaddr, write, size):
        """virtual -> physical, raising what the chip raises"""
        vaddr &= M64
        if vaddr & (size - 1):
            self.address_exception(vaddr)
            raise Exc(ADES if write else ADEL)
        if not self.bits64():
            if sx32(vaddr) != vaddr:
                self.address_exception(vaddr)
                raise Exc(ADES if write else ADEL)
            seg = (vaddr >> 29) & 7
            if self.kernel():
                if seg == 4 or seg == 5:
                    return vaddr & 0x1FFFFFFF
                return self.tlb_lookup(vaddr, write)
            mode = (self.status >> 3) & 3
            if mode == 1 and (seg < 4 or seg == 6):
                return self.tlb_lookup(vaddr, write)
            if mode == 2 and seg < 4:
                return self.tlb_lookup(vaddr, write)
            self.address_exception(vaddr)
            raise Exc(ADES if write else ADEL)
        # 64-bit addressing (kernel only here; enough for what games do)
        if 0xFFFFFFFF80000000 <= vaddr <= 0xFFFFFFFFBFFFFFFF:
            return vaddr & 0x1FFFFFFF
        if 0x8000000000000000 <= vaddr <= 0xBFFFFFFFFFFFFFFF and (vaddr & 0x07FFFFFF00000000) == 0:
            return vaddr & M32
        if vaddr <= 0x000000FFFFFFFFFF or 0x4000000000000000 <= vaddr <= 0x400000FFFFFFFFFF \
                or 0xC000000000000000 <= vaddr <= 0xC00000FF7FFFFFFF or vaddr >= 0xFFFFFFFFC0000000:
            return self.tlb_lookup(vaddr, write)
        self.address_exception(vaddr)
        raise Exc(ADES if write else ADEL)

    def tlb_lookup(self, vaddr, write):
        asid = self.entry.asid
        for e in self.tlb:
            if not e.g and e.asid != asid:
                continue
            if (vaddr & e.mask_hi) != e.vpn:
                continue
            if (vaddr >> 62) != e.region:
                continue
            lo = 1 if vaddr & e.select else 0
            if not e.v[lo]:
                self.address_exception(vaddr)
                raise Exc(TLBS if write else TLBL)
            if write and not e.d[lo]:
                self.address_exception(vaddr)
                raise Exc(MOD)
            return (e.pfn[lo] + (vaddr & e.mask_lo)) & M32
        self.address_exception(vaddr)
        raise Exc(TLBS if write else TLBL, tlb_miss=True)

    def load(self, vaddr, size):
        return self.bus.read(self.translate(vaddr, False, size), size)

    def store(self, vaddr, size, value):
        self.bus.write(self.translate(vaddr, True, size), size, value & ((1 << (8 * size)) - 1))

    # --- exceptions -----------------------------------------------------------------
    def take(self, e):
        self.last_exc = e.code
        base = 0xFFFFFFFFBFC00200 if self.status & (1 << 22) else 0xFFFFFFFF80000000
        off = 0x180
        if e.tlb_miss and not (self.status & 2):
            off = 0x080 if self.bits64() else 0x000
        if not (self.status & 2):
            self.epc = self.pc
            bd = self.delay
            if bd:
                self.epc = (self.pc - 4) & M64
            self.cause = (self.cause & ~0x8000007C) | (e.code << 2) | (bd << 31)
            self.status |= 2
        else:
            self.cause = (self.cause & ~0x7C) | (e.code << 2)
        self.cause = (self.cause & ~(3 << 28)) | (e.ce << 28)
        self.pc = (base + off) & M64
        self.npc = (self.pc + 4) & M64
        self.next_delay = False

    def interrupt_pending(self):
        if (self.status & 7) != 1:       # IE and not EXL/ERL
            return False
        return (self.cause >> 8) & (self.status >> 8) & 0xFF

    # --- COP0 registers -------------------------------------------------------------
    def random(self):
        if self.wired > 31:
            return self.random_state & 63
        n = 32 - self.wired
        return self.wired + (self.instructions % n)

    def cop0_read(self, i):
        e = self.entry
        if i == 0: return self.index | (self.probe_fail << 31)
        if i == 1: return self.random()
        if i in (2, 3):
            k = i - 2
            return e.gl[k] | (e.v[k] << 1) | (e.d[k] << 2) | (e.c[k] << 3) | (((e.pfn[k] >> 12) & 0xFFFFFF) << 6)
        if i == 4: return (self.context_bad << 4) | (self.context_ptebase << 23)
        if i == 5: return e.page_mask & (0xFFF << 13)
        if i == 6: return self.wired
        if i == 8: return self.badvaddr
        if i == 9: return (self.count >> 1) & M32
        if i == 10: return e.asid | (e.vpn & (((1 << 27) - 1) << 13)) | (e.region << 62)
        if i == 11: return (self.compare >> 1) & M32
        if i == 12: return self.status
        if i == 13: return self.cause
        if i == 14: return self.epc
        if i == 15: return 0x0B22
        if i == 16: return self.config
        if i == 17: return self.ll
        if i == 20: return (self.xcontext_bad << 4) | (self.xcontext_region << 31) | (self.xcontext_ptebase << 33)
        if i == 28: return self.taglo
        if i == 29: return 0
        if i == 30: return self.errorepc
        return self.latch

    def cop0_write(self, i, v):
        self.latch = v
        e = self.entry
        if i == 0: self.index = v & 63; self.probe_fail = (v >> 31) & 1
        elif i in (2, 3):
            k = i - 2
            e.gl[k] = v & 1; e.v[k] = (v >> 1) & 1; e.d[k] = (v >> 2) & 1; e.c[k] = (v >> 3) & 7
            e.pfn[k] = ((v >> 6) & 0xFFFFFF) << 12
        elif i == 4: self.context_ptebase = (v >> 23) & ((1 << 41) - 1)
        elif i == 5: e.page_mask = v & (0xFFF << 13)
        elif i == 6: self.wired = v & 63
        elif i == 9: self.count = (v & M32) << 1
        elif i == 10:
            e.asid = v & 0xFF; e.vpn = v & (((1 << 27) - 1) << 13); e.region = (v >> 62) & 3
        elif i == 11:
            self.compare = (v & M32) << 1
            self.cause &= ~(1 << 15)
        elif i == 12: self.status = v & 0xFFFFFFFF & ~(1 << 21) | (self.status & (1 << 21))
        elif i == 13: self.cause = (self.cause & ~0x300) | (v & 0x300)
        elif i == 14: self.epc = v & M64
        elif i == 16: self.config = (self.config & ~0x0F00800F) | (v & 0x0F00800F)
        elif i == 17: self.ll = v & M32
        elif i == 20: self.xcontext_ptebase = (v >> 33) & ((1 << 31) - 1)
        elif i == 28: self.taglo = v & M32
        elif i == 30: self.errorepc = v & M64

    # --- the step --------------------------------------------------------------------
    def step(self):
        self.last_exc = None
        self.instructions += 1
        self.count = (self.count + 1) & ((1 << 33) - 1)
        if self.count == self.compare:
            self.cause |= 1 << 15
        self.cause = (self.cause & ~(1 << 10)) | (self.bus.mi_irq() << 10)
        if self.interrupt_pending():
            self.delay = self.next_delay
            self.take(Exc(INT))
            return
        self.delay = self.next_delay
        self.next_delay = False
        pc = self.pc
        try:
            word = self.load(pc, 4)
            self.pc, self.npc = self.npc, (self.npc + 4) & M64
            self.execute(word, pc)
        except Exc as e:
            self.pc = pc                  # EPC is the instruction that faulted
            self.take(e)
        self.r[0] = 0

    # branch helpers: `pc` is the branch's own address
    def branch(self, pc, target):
        self.npc = target & M64
        self.next_delay = True

    def no_branch(self):
        self.next_delay = True

    def skip(self):
        self.pc = self.npc
        self.npc = (self.npc + 4) & M64

    def execute(self, w, pc):
        op = w >> 26
        rs = (w >> 21) & 31
        rt = (w >> 16) & 31
        rd = (w >> 11) & 31
        sa = (w >> 6) & 31
        imm = w & 0xFFFF
        simm = sx16(imm)
        r = self.r
        tgt = (pc + 4 + (simm << 2)) & M64

        if op == 0:
            fn = w & 63
            a, b = r[rs], r[rt]
            if fn == 0x00: r[rd] = sx32(b << sa)
            elif fn == 0x02: r[rd] = sx32((b & M32) >> sa)
            elif fn == 0x03: r[rd] = sx32(s64(b) >> sa)
            elif fn == 0x04: r[rd] = sx32(b << (a & 31))
            elif fn == 0x06: r[rd] = sx32((b & M32) >> (a & 31))
            elif fn == 0x07: r[rd] = sx32(s64(b) >> (a & 31))
            elif fn == 0x08: self.branch(pc, a)
            elif fn == 0x09:
                r[rd] = (pc + 8) & M64
                self.branch(pc, a)
            elif fn == 0x0C: raise Exc(SYS)
            elif fn == 0x0D: raise Exc(BP)
            elif fn == 0x0F: pass                                  # SYNC
            elif fn == 0x10: r[rd] = self.hi
            elif fn == 0x11: self.hi = a
            elif fn == 0x12: r[rd] = self.lo
            elif fn == 0x13: self.lo = a
            elif fn == 0x14: self.d64(); r[rd] = (b << (a & 63)) & M64
            elif fn == 0x16: self.d64(); r[rd] = b >> (a & 63)
            elif fn == 0x17: self.d64(); r[rd] = (s64(b) >> (a & 63)) & M64
            elif fn == 0x18:                                       # MULT: rs (64) x rt (35)
                bb = s64(b)
                bb = ((bb << 29) & M64)
                bb = s64(bb) >> 29
                p = (s64(a) * bb) & M64
                self.lo, self.hi = sx32(p), sx32(p >> 32)
            elif fn == 0x19:
                p = (a & M32) * (b & M32)
                self.lo, self.hi = sx32(p), sx32(p >> 32)
            elif fn == 0x1A:                                       # DIV
                if s64(b) != 0:
                    n, d = s32(a), s64(b)
                    q = abs(n) // abs(d)
                    if (n < 0) != (d < 0):
                        q = -q
                    self.lo, self.hi = sx32(q), sx32(n - q * d)
                else:
                    self.lo = 1 if s32(a) < 0 else M64
                    self.hi = sx32(a)
            elif fn == 0x1B:                                       # DIVU
                if b & M32:
                    self.lo, self.hi = sx32((a & M32) // (b & M32)), sx32((a & M32) % (b & M32))
                else:
                    self.lo, self.hi = M64, sx32(a)
            elif fn == 0x1C:
                self.d64()
                p = (s64(a) * s64(b)) & ((1 << 128) - 1)
                self.lo, self.hi = p & M64, p >> 64
            elif fn == 0x1D:
                self.d64()
                p = a * b
                self.lo, self.hi = p & M64, p >> 64
            elif fn == 0x1E:                                       # DDIV
                self.d64()
                n, d = s64(a), s64(b)
                if d:
                    q = abs(n) // abs(d)
                    if (n < 0) != (d < 0):
                        q = -q
                    self.lo, self.hi = q & M64, (n - q * d) & M64
                else:
                    self.lo, self.hi = (1 if n < 0 else M64), a
            elif fn == 0x1F:
                self.d64()
                if b:
                    self.lo, self.hi = a // b, a % b
                else:
                    self.lo, self.hi = M64, a
            elif fn == 0x20:
                if ~(a ^ b) & (a ^ (a + b)) & 0x80000000: raise Exc(OV)
                r[rd] = sx32(a + b)
            elif fn == 0x21: r[rd] = sx32(a + b)
            elif fn == 0x22:
                if (a ^ b) & (a ^ (a - b)) & 0x80000000: raise Exc(OV)
                r[rd] = sx32(a - b)
            elif fn == 0x23: r[rd] = sx32(a - b)
            elif fn == 0x24: r[rd] = a & b
            elif fn == 0x25: r[rd] = a | b
            elif fn == 0x26: r[rd] = a ^ b
            elif fn == 0x27: r[rd] = ~(a | b) & M64
            elif fn == 0x2A: r[rd] = 1 if s64(a) < s64(b) else 0
            elif fn == 0x2B: r[rd] = 1 if a < b else 0
            elif fn == 0x2C:
                self.d64()
                s = (a + b) & M64
                if ~(a ^ b) & (a ^ s) & (1 << 63): raise Exc(OV)
                r[rd] = s
            elif fn == 0x2D: self.d64(); r[rd] = (a + b) & M64
            elif fn == 0x2E:
                self.d64()
                s = (a - b) & M64
                if (a ^ b) & (a ^ s) & (1 << 63): raise Exc(OV)
                r[rd] = s
            elif fn == 0x2F: self.d64(); r[rd] = (a - b) & M64
            elif fn == 0x30:
                if s64(a) >= s64(b): raise Exc(TR)
            elif fn == 0x31:
                if a >= b: raise Exc(TR)
            elif fn == 0x32:
                if s64(a) < s64(b): raise Exc(TR)
            elif fn == 0x33:
                if a < b: raise Exc(TR)
            elif fn == 0x34:
                if a == b: raise Exc(TR)
            elif fn == 0x36:
                if a != b: raise Exc(TR)
            elif fn == 0x38: self.d64(); r[rd] = (b << sa) & M64
            elif fn == 0x3A: self.d64(); r[rd] = b >> sa
            elif fn == 0x3B: self.d64(); r[rd] = (s64(b) >> sa) & M64
            elif fn == 0x3C: self.d64(); r[rd] = (b << (sa + 32)) & M64
            elif fn == 0x3E: self.d64(); r[rd] = b >> (sa + 32)
            elif fn == 0x3F: self.d64(); r[rd] = (s64(b) >> (sa + 32)) & M64
            else: raise Exc(RI)
            return

        if op == 1:                                                # REGIMM
            a = s64(r[rs])
            if rt in (0x10, 0x11, 0x12, 0x13):
                link = True
            else:
                link = False
            c = rt & 0x1F
            if c in (0x00, 0x02, 0x10, 0x12): cond = a < 0
            elif c in (0x01, 0x03, 0x11, 0x13): cond = a >= 0
            elif c == 0x08:
                if a >= s64(simm): raise Exc(TR)
                return
            elif c == 0x09:
                if r[rs] >= simm: raise Exc(TR)
                return
            elif c == 0x0A:
                if a < s64(simm): raise Exc(TR)
                return
            elif c == 0x0B:
                if r[rs] < simm: raise Exc(TR)
                return
            elif c == 0x0C:
                if a == s64(simm): raise Exc(TR)
                return
            elif c == 0x0E:
                if a != s64(simm): raise Exc(TR)
                return
            else:
                raise Exc(RI)
            if link:
                r[31] = sx32(pc + 8)
            likely = c & 2
            if cond: self.branch(pc, tgt)
            elif likely: self.skip()
            else: self.no_branch()
            return

        if op == 2 or op == 3:                                     # J, JAL
            if op == 3:
                r[31] = (pc + 8) & M64
            self.branch(pc, ((pc + 4) & 0xFFFFFFFFF0000000) | ((w & 0x3FFFFFF) << 2))
            return

        if 4 <= op <= 7 or 0x14 <= op <= 0x17:                     # BEQ BNE BLEZ BGTZ (+likely)
            a, b = r[rs], r[rt]
            k = op & 3
            if k == 0: cond = a == b
            elif k == 1: cond = a != b
            elif k == 2: cond = s64(a) <= 0
            else: cond = s64(a) > 0
            if cond: self.branch(pc, tgt)
            elif op >= 0x14: self.skip()
            else: self.no_branch()
            return

        if op == 0x08:                                             # ADDI
            a = r[rs]
            if ~(a ^ simm) & (a ^ (a + simm)) & 0x80000000: raise Exc(OV)
            r[rt] = sx32(a + simm)
        elif op == 0x09: r[rt] = sx32(r[rs] + simm)
        elif op == 0x0A: r[rt] = 1 if s64(r[rs]) < s64(simm) else 0
        elif op == 0x0B: r[rt] = 1 if r[rs] < simm else 0
        elif op == 0x0C: r[rt] = r[rs] & imm
        elif op == 0x0D: r[rt] = r[rs] | imm
        elif op == 0x0E: r[rt] = r[rs] ^ imm
        elif op == 0x0F: r[rt] = sx32(imm << 16)
        elif op == 0x10: self.cop0(w, rs, rt, rd)
        elif op == 0x11: self.cop1(w)
        elif op == 0x18:
            self.d64()
            a = r[rs]
            s = (a + simm) & M64
            if ~(a ^ simm) & (a ^ s) & (1 << 63): raise Exc(OV)
            r[rt] = s
        elif op == 0x19: self.d64(); r[rt] = (r[rs] + simm) & M64
        elif op == 0x1A: self.ldl(rt, (r[rs] + simm) & M64)
        elif op == 0x1B: self.ldr(rt, (r[rs] + simm) & M64)
        elif op == 0x20: r[rt] = sx8(self.load(r[rs] + simm, 1))
        elif op == 0x21: r[rt] = sx16(self.load(r[rs] + simm, 2))
        elif op == 0x22: self.lwl(rt, (r[rs] + simm) & M64)
        elif op == 0x23: r[rt] = sx32(self.load(r[rs] + simm, 4))
        elif op == 0x24: r[rt] = self.load(r[rs] + simm, 1)
        elif op == 0x25: r[rt] = self.load(r[rs] + simm, 2)
        elif op == 0x26: self.lwr(rt, (r[rs] + simm) & M64)
        elif op == 0x27: r[rt] = self.load(r[rs] + simm, 4)
        elif op == 0x28: self.store(r[rs] + simm, 1, r[rt])
        elif op == 0x29: self.store(r[rs] + simm, 2, r[rt])
        elif op == 0x2A: self.swl(r[rt], (r[rs] + simm) & M64)
        elif op == 0x2B: self.store(r[rs] + simm, 4, r[rt])
        elif op == 0x2C: self.sdl(r[rt], (r[rs] + simm) & M64)
        elif op == 0x2D: self.sdr(r[rt], (r[rs] + simm) & M64)
        elif op == 0x2E: self.swr(r[rt], (r[rs] + simm) & M64)
        elif op == 0x2F:                                           # CACHE: the model has no caches,
            if not self.kernel() and not (self.status & (1 << 28)):  # but the checks are the chip's
                raise Exc(CPU_, 0)
            self.translate((r[rs] + simm) & M64, False, 4)
        elif op == 0x30:                                           # LL
            va = (r[rs] + simm) & M64
            pa = self.translate(va, False, 4)
            r[rt] = sx32(self.bus.read(pa, 4))
            self.ll, self.llbit = pa >> 4, 1
        elif op == 0x34:                                           # LLD
            self.d64()
            va = (r[rs] + simm) & M64
            pa = self.translate(va, False, 8)
            r[rt] = self.bus.read(pa, 8)
            self.ll, self.llbit = pa >> 4, 1
        elif op == 0x37: self.d64(); r[rt] = self.load(r[rs] + simm, 8)
        elif op == 0x38:                                           # SC
            if self.llbit:
                self.store(r[rs] + simm, 4, r[rt])
                r[rt] = 1
            else:
                r[rt] = 0
        elif op == 0x3C:                                           # SCD
            self.d64()
            if self.llbit:
                self.store(r[rs] + simm, 8, r[rt])
                r[rt] = 1
            else:
                r[rt] = 0
        elif op == 0x3F: self.d64(); self.store(r[rs] + simm, 8, r[rt])
        elif op in (0x31, 0x35, 0x39, 0x3D):                       # LWC1 LDC1 SWC1 SDC1
            self.cop1(w)
        else:
            raise Exc(RI)

    def d64(self):
        """the 64-bit instructions are reserved in 32-bit user and supervisor modes"""
        if not self.kernel() and not self.bits64():
            raise Exc(RI)

    # --- unaligned loads and stores, big-endian ------------------------------------
    def lwl(self, rt, va):
        word = self.load(va & ~3, 4)
        k = va & 3
        keep = (1 << (8 * k)) - 1
        data = ((word << (8 * k)) & M32) | (self.r[rt] & keep)
        self.r[rt] = sx32(data)

    def lwr(self, rt, va):
        word = self.load(va & ~3, 4)
        k = va & 3
        sh = 8 * (3 - k)
        keep = (M32 ^ (M32 >> sh)) & M32
        data = (self.r[rt] & keep) | (word >> sh)
        if k == 3:
            self.r[rt] = sx32(data)
        else:
            self.r[rt] = (self.r[rt] & 0xFFFFFFFF00000000) | (data & M32)

    def ldl(self, rt, va):
        self.d64()
        mem = self.load(va & ~7, 8)
        k = va & 7
        keep = (1 << (8 * k)) - 1
        self.r[rt] = ((mem << (8 * k)) & M64) | (self.r[rt] & keep)

    def ldr(self, rt, va):
        self.d64()
        mem = self.load(va & ~7, 8)
        k = va & 7
        sh = 8 * (7 - k)
        keep = M64 ^ (M64 >> sh)
        self.r[rt] = (self.r[rt] & keep) | (mem >> sh)

    def _store_bytes(self, va, data_bytes):
        """the bytes of an aligned word that SWL/SWR write (None: left alone)"""
        pa = self.translate(va & ~3, True, 1)
        for i, b in enumerate(data_bytes):
            if b is not None:
                self.bus.write(pa + i, 1, b)

    def swl(self, v, va):
        k = va & 3
        word = struct.pack('>I', v & M32)
        bytes4 = [None] * 4
        for i in range(k, 4):
            bytes4[i] = word[i - k]
        self._store_bytes(va, bytes4)

    def swr(self, v, va):
        k = va & 3
        word = struct.pack('>I', v & M32)
        bytes4 = [None] * 4
        for i in range(0, k + 1):
            bytes4[i] = word[3 - k + i]
        self._store_bytes(va, bytes4)

    def sdl(self, v, va):
        self.d64()
        k = va & 7
        d = struct.pack('>Q', v & M64)
        b8 = [None] * 8
        for i in range(k, 8):
            b8[i] = d[i - k]
        self._store_bytes8(va, b8)

    def sdr(self, v, va):
        self.d64()
        k = va & 7
        d = struct.pack('>Q', v & M64)
        b8 = [None] * 8
        for i in range(0, k + 1):
            b8[i] = d[7 - k + i]
        self._store_bytes8(va, b8)

    def _store_bytes8(self, va, b8):
        pa = self.translate(va & ~7, True, 1)
        for i, b in enumerate(b8):
            if b is not None:
                self.bus.write(pa + i, 1, b)

    # --- coprocessors ---------------------------------------------------------------
    def cop0(self, w, rs, rt, rd):
        if not self.kernel() and not (self.status & (1 << 28)):
            raise Exc(CPU_, 0)
        r = self.r
        if rs == 0x00: r[rt] = sx32(self.cop0_read(rd))
        elif rs == 0x01: r[rt] = self.cop0_read(rd) & M64
        elif rs == 0x04: self.cop0_write(rd, r[rt])
        elif rs == 0x05: self.cop0_write(rd, r[rt])
        elif rs & 0x10:
            fn = w & 63
            if fn == 0x01:                                         # TLBR
                if self.index < 32:
                    self.entry = self.tlb[self.index].copy()
            elif fn == 0x02:                                       # TLBWI
                if self.index < 32:
                    e = self.entry.copy(); e.sync(); self.tlb[self.index] = e
            elif fn == 0x06:                                       # TLBWR
                i = self.random()
                if i < 32:
                    e = self.entry.copy(); e.sync(); self.tlb[i] = e
            elif fn == 0x08:                                       # TLBP
                self.index, self.probe_fail = 0, 1
                h = self.entry
                for i, e in enumerate(self.tlb):
                    m = ~e.page_mask & ~0x1FFF & ((1 << 40) - 1)
                    if (e.vpn & m) != (h.vpn & m) or e.region != h.region:
                        continue
                    if not e.g and e.asid != h.asid:
                        continue
                    self.index, self.probe_fail = i, 0
                    break
            elif fn == 0x18:                                       # ERET
                if self.status & 4:
                    self.pc = self.errorepc
                    self.status &= ~4
                else:
                    self.pc = self.epc
                    self.status &= ~2
                self.npc = (self.pc + 4) & M64
                self.next_delay = False
                self.llbit = 0
            else:
                raise Exc(RI)
        else:
            raise Exc(RI)

    def cop1(self, w):
        # the FPU is a later step; until then it is a coprocessor-unusable
        # exception when disabled, and a reserved instruction when enabled
        if not (self.status & (1 << 29)):
            raise Exc(CPU_, 1)
        raise Exc(RI)


class N64:
    """the machine around the CPU, as far as the CPU tests need it"""
    RDRAM = 8 << 20

    def __init__(self, rom):
        self.rom = rom
        self.rdram = bytearray(self.RDRAM)
        self.dmem = bytearray(0x1000)
        self.imem = bytearray(0x1000)
        self.pifram = bytearray(64)
        self.pifrom = bytearray(0x7C0)     # the boot stub (see boot_stub), not Nintendo's
        self.vi = [0] * 14
        self.pi = [0] * 13
        self.mi_intr = 0
        self.mi_mask = 0
        self.mi_mode = 0
        self.sp_status = 1          # halted
        self.si_status = 0
        self.ai = [0] * 6
        self.cpu = VR4300(self)
        self.vi_cycle = 0
        self.vi_polls = 0          # reads of VI_V_CURRENT
        self.vi_frames = 0
        self.rdram_writes = 0      # a finished test has stopped writing

    # --- the bus ------------------------------------------------------------------------
    def read(self, a, n):
        if a < self.RDRAM:
            return int.from_bytes(self.rdram[a:a + n], 'big')
        if 0x04000000 <= a < 0x04002000:
            m = self.dmem if a < 0x04001000 else self.imem
            o = a & 0xFFF
            return int.from_bytes(m[o:o + n], 'big')
        if 0x10000000 <= a < 0x1FC00000:
            o = a - 0x10000000
            chunk = self.rom[o:o + n]
            return int.from_bytes(chunk.ljust(n, b'\0'), 'big')
        if 0x1FC007C0 <= a < 0x1FC00800:
            o = a - 0x1FC007C0
            return int.from_bytes(self.pifram[o:o + n], 'big')
        if 0x1FC00000 <= a < 0x1FC007C0:
            o = a - 0x1FC00000
            return int.from_bytes(self.pifrom[o:o + n], 'big')
        # registers: 32-bit; a narrower read takes its bytes of the word
        w = self.reg_read(a & ~3)
        if n == 4:
            return w
        if n == 8:
            return (w << 32) | self.reg_read((a & ~3) + 4)
        sh = 8 * (4 - n - (a & 3))
        return (w >> sh) & ((1 << (8 * n)) - 1)

    def write(self, a, n, v):
        if a < self.RDRAM:
            self.rdram[a:a + n] = v.to_bytes(n, 'big')
            self.rdram_writes += 1
            return
        if 0x04000000 <= a < 0x04002000:
            m = self.dmem if a < 0x04001000 else self.imem
            o = a & 0xFFF
            m[o:o + n] = v.to_bytes(n, 'big')
            return
        if 0x1FC007C0 <= a < 0x1FC00800:
            o = a - 0x1FC007C0
            self.pifram[o:o + n] = v.to_bytes(n, 'big')
            return
        if 0x10000000 <= a < 0x1FC00000:
            return
        if n == 8:
            self.reg_write(a & ~7, v >> 32)
            self.reg_write((a & ~7) + 4, v & M32)
        elif n == 4:
            self.reg_write(a, v)
        else:
            # narrow register writes put the value in its lane of the word
            sh = 8 * (4 - n - (a & 3))
            self.reg_write(a & ~3, (v & ((1 << (8 * n)) - 1)) << sh)

    def reg_read(self, a):
        if 0x04040000 <= a < 0x04040020:
            i = (a >> 2) & 7
            if i == 4: return self.sp_status
            return 0
        if a == 0x04080000: return 0
        if 0x04300000 <= a < 0x04300010:
            i = (a >> 2) & 3
            return [self.mi_mode, 0x02020102, self.mi_intr, self.mi_mask][i]
        if 0x04400000 <= a < 0x04400038:
            i = (a >> 2) & 15
            if i == 4:
                self.vi_polls += 1
                return self.vi_line()
            return self.vi[i]
        if 0x04500000 <= a < 0x04500018:
            return 0
        if 0x04600000 <= a < 0x04600034:
            i = (a >> 2) & 15
            if i == 4: return 0           # PI_STATUS: never busy (DMA is instant here)
            return self.pi[i]
        if 0x04700000 <= a < 0x04700020: return 0
        if 0x04800000 <= a < 0x0480001C:
            return self.si_status if a == 0x04800018 else 0
        if 0x03F00000 <= a < 0x04000000: return 0
        return 0

    def reg_write(self, a, v):
        v &= M32
        if 0x04040000 <= a < 0x04040020:
            i = (a >> 2) & 7
            if i == 4:
                if v & 1: self.sp_status &= ~1      # clear halt (the RSP is not modelled yet)
                if v & 2: self.sp_status |= 1
                if v & 8: self.mi_intr &= ~1
                if v & 16: self.mi_intr |= 1
            return
        if 0x04300000 <= a < 0x04300010:
            i = (a >> 2) & 3
            if i == 0:
                self.mi_mode = v & 0x7F
                if v & (1 << 11): self.mi_intr &= ~0x20       # clear DP interrupt
            elif i == 3:
                for bit in range(6):
                    if v & (1 << (2 * bit)): self.mi_mask &= ~(1 << bit)
                    if v & (1 << (2 * bit + 1)): self.mi_mask |= 1 << bit
            return
        if 0x04400000 <= a < 0x04400038:
            i = (a >> 2) & 15
            if i == 4:
                self.mi_intr &= ~0x08                          # writing V_CURRENT clears the VI interrupt
            else:
                self.vi[i] = v
            return
        if 0x04500000 <= a < 0x04500018:
            i = (a >> 2) & 7
            if i == 3: self.mi_intr &= ~0x04
            elif i < 6: self.ai[i] = v
            return
        if 0x04600000 <= a < 0x04600034:
            i = (a >> 2) & 15
            if i == 4:
                if v & 2: self.mi_intr &= ~0x10
                return
            self.pi[i] = v
            if i == 3:                                          # PI_WR_LEN: cartridge -> RDRAM
                dram = self.pi[0] & 0x00FFFFFE
                cart = self.pi[1] & 0xFFFFFFFE
                length = (v & 0x00FFFFFF) + 1
                for k in range(length):
                    if dram + k < self.RDRAM:
                        self.rdram[dram + k] = self.read(cart + k, 1)
                self.mi_intr |= 0x10
            elif i == 2:                                        # PI_RD_LEN: RDRAM -> cartridge (ignored)
                self.mi_intr |= 0x10
            return
        if 0x04800000 <= a < 0x0480001C:
            if a == 0x04800018:
                self.mi_intr &= ~0x02
            return

    def mi_irq(self):
        self.vi_tick()
        return 1 if (self.mi_intr & self.mi_mask) else 0

    # --- the VI's time --------------------------------------------------------------------
    # NTSC is 525 half-lines a frame at 60 frames a second: about 2,976 cycles a
    # half-line at 93.75 MHz. The model counts instructions, not cycles, and no
    # test it runs depends on the true rate (the timing tests are for hardware),
    # so its frame is short: waiting for a scanline costs a fraction as much.
    HALFLINE = 200

    def vi_line(self):
        """V_CURRENT: the half-line being scanned, 0 .. V_SYNC"""
        vsync = (self.vi[6] & 0x3FF) or 525
        return (self.vi_cycle // self.HALFLINE) % (vsync + 1)

    def vi_tick(self):
        self.vi_cycle += 1
        if self.vi_cycle % self.HALFLINE == 0:
            line = self.vi_line()
            if line == (self.vi[3] & 0x3FF):
                self.mi_intr |= 0x08
            if line == 0:
                self.vi_frames += 1

    # --- the boot, without a PIF ROM -------------------------------------------------------
    def fast_boot(self):
        rom = self.rom
        entry = int.from_bytes(rom[8:12], 'big')
        size = min(1 << 20, max(0, len(rom) - 0x1000))
        pa = entry & 0x1FFFFFFF
        self.rdram[pa:pa + size] = rom[0x1000:0x1000 + size]
        self.dmem[0:0x1000] = rom[0:0x1000].ljust(0x1000, b'\0')
        # what IPL3 leaves in low memory: TV type, ROM base, reset type, CIC, version, size
        for off, val in ((0x300, 1), (0x304, 0), (0x308, 0xB0000000), (0x30C, 0),
                         (0x310, 0x3F), (0x314, 0), (0x318, self.RDRAM)):
            self.rdram[off:off + 4] = val.to_bytes(4, 'big')
        c = self.cpu
        c.status = STATUS_AFTER_IPL3
        c.r[29] = 0xFFFFFFFFA4001FF0                  # sp
        c.r[20] = 1                                   # s4: NTSC
        c.r[22] = 0x3F                                # s6: CIC seed (6102)
        c.pc = sx32(entry)
        c.npc = (c.pc + 4) & M64
        self.vi[0] = 0
        self.pi[5:9] = [rom[3], rom[2], rom[1], rom[0]] if len(rom) > 4 else [0] * 4

    def stub_boot(self):
        """The same as fast_boot, but the registers are set by a few instructions
        at the reset address instead of from outside -- the way the hardware does
        it, so a trace of this machine and of the RTL start at one place."""
        self.fast_boot()
        words = boot_stub(int.from_bytes(self.rom[8:12], 'big'))
        for i, w in enumerate(words):
            self.pifrom[4 * i:4 * i + 4] = w.to_bytes(4, 'big')
        c = self.cpu
        c.r = [0] * 32
        c.status = 0x34000000 | (1 << 22) | (1 << 2)
        c.pc = 0xFFFFFFFFBFC00000
        c.npc = c.pc + 4
        return words

    # --- the picture -------------------------------------------------------------------------
    def framebuffer(self):
        """(width, height, rgb bytes) from the VI's registers"""
        status, origin, width = self.vi[0], self.vi[1] & 0xFFFFFF, self.vi[2] & 0xFFF
        kind = status & 3
        if kind < 2 or not width:
            return 0, 0, b''
        # Y_SCALE is 2.10 fixed point: framebuffer lines per 240 displayed
        yscale = self.vi[13] & 0xFFF
        height = min(480, (yscale * 240) >> 10) if yscale else 240
        out = bytearray()
        for y in range(height):
            row = origin + y * width * (4 if kind == 3 else 2)
            for x in range(width):
                if kind == 3:
                    p = row + 4 * x
                    out += self.rdram[p:p + 3]
                else:
                    p = row + 2 * x
                    v = (self.rdram[p] << 8) | self.rdram[p + 1]
                    out += bytes((((v >> 11) & 31) << 3, ((v >> 6) & 31) << 3, ((v >> 1) & 31) << 3))
        return width, height, bytes(out)


# Status as the cartridge's boot code (IPL3) leaves it: CU1, FR, SR, and
# 64-bit addressing in all three modes (KX SX UX). krom's exception tests read
# it back from hardware as 241000E0. (34000000, which some emulators use, is
# the state before IPL3 runs.)
STATUS_AFTER_IPL3 = 0x241000E0


def boot_stub(entry):
    """what runs at the reset address instead of the PIF ROM: Status, the stack,
    the CIC registers the boot code leaves (s4 = NTSC, s6 = the 6102 seed), and a
    jump to the game's entry point"""
    sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
    from mipsasm import Asm, T0, SP, S4, S6, ZERO
    a = Asm(org=0xBFC00000)
    a.lui(T0, STATUS_AFTER_IPL3 >> 16); a.ori(T0, T0, STATUS_AFTER_IPL3 & 0xFFFF); a.mtc0(T0, 12)
    a.lui(SP, 0xA400); a.ori(SP, SP, 0x1FF0)
    a.ori(S4, ZERO, 1); a.ori(S6, ZERO, 0x3F)
    a.lui(T0, entry >> 16); a.ori(T0, T0, entry & 0xFFFF)
    a.jr(T0); a.nop()
    return a.words()


def write_png(path, w, h, rgb):
    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & M32)
    raw = b''.join(b'\0' + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b'')
    open(path, 'wb').write(png)


def run(m, steps, idle=200_000, trace=False):
    """Run until `steps`, or until the program is plainly finished: two whole
    video frames in which it wrote nothing to RDRAM (a finished test only waits
    on the VI), or `idle` steps spun on one address."""
    c = m.cpu
    seen_pc, same = None, 0
    frame, writes, quiet = m.vi_frames, m.rdram_writes, 0
    for i in range(steps):
        if trace:
            print('%016x %08x' % (c.pc, m.read(c.translate(c.pc, False, 4), 4)))
        c.step()
        if m.vi_frames != frame:
            quiet = quiet + 1 if m.rdram_writes == writes else 0
            frame, writes = m.vi_frames, m.rdram_writes
            if quiet >= 2:
                break
        if i & 63 == 0:
            if c.pc == seen_pc:
                same += 64
                if same > idle:
                    break
            else:
                seen_pc, same = c.pc, 0


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('rom')
    ap.add_argument('--steps', type=int, default=20_000_000)
    ap.add_argument('--png', default='')
    ap.add_argument('--trace', action='store_true')
    ap.add_argument('--stop-when-idle', type=int, default=200_000,
                    help='stop after this many steps spent in one tight loop')
    args = ap.parse_args()
    rom = open(args.rom, 'rb').read()
    if rom[:4] == b'\x37\x80\x40\x12':                 # byte-swapped (.v64)
        rom = bytes(b for i in range(0, len(rom), 2) for b in (rom[i + 1], rom[i]))
    m = N64(rom)
    m.fast_boot()
    c = m.cpu
    import time
    t0 = time.time()
    run(m, args.steps, args.stop_when_idle, args.trace)
    dt = time.time() - t0
    print('%d instructions in %.1f s (%.0f k/s); pc %016x' % (c.instructions, dt, c.instructions / dt / 1000, c.pc))
    if args.png:
        w, h, rgb = m.framebuffer()
        if w:
            write_png(args.png, w, h, rgb)
            print('framebuffer %dx%d -> %s' % (w, h, args.png))
        else:
            print('the VI shows no framebuffer (status %08x)' % m.vi[0])


if __name__ == '__main__':
    main()
