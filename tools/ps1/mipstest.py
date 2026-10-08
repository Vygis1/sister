"""Generate a self-checking R3000 test program, with the answers worked out here.

    python tools/ps1/mipstest.py sim/roms/mips/mipstest.hex

Same shape as m68ktest.py, for the same reason: every case is computed twice,
once in Python by the rules in the manual and once by the Verilog by whatever
it actually does, and the program stops at the first disagreement and says
which case it was and what both sides produced. This is the only way a CPU has
been got right in this tree, three times now.

What is swept, in order:

  1. the ALU, register and immediate forms, over operand pairs on the flag and
     overflow boundaries -- and the immediates twice, because ANDI/ORI/XORI
     zero-extend theirs and ADDI/SLTI sign-extend, which is the single most
     common R3000 bug
  2. shifts, by immediate and by register, including the "only the low five
     bits of the register count" rule
  3. multiply and divide, into HI and LO, including divide by zero and the
     overflow case, which do NOT trap on this chip -- they produce particular
     values, and a game that divides by zero gets them
  4. loads and stores of every width and sign, and the unaligned four
     (LWL/LWR/SWL/SWR), which a PlayStation's memcpy uses constantly
  5. the load delay slot: the instruction after a load sees the OLD register,
     which is not a quirk to paper over but the architecture, and code exists
     that relies on it
  6. branches, taken and not, with the delay slot proven executed; JAL and
     JALR's link value of the branch's own address plus eight
  7. exceptions: arithmetic overflow, SYSCALL, BREAK, misaligned loads, each
     with the right ExcCode and EPC, returned from with RFE; and an external
     interrupt, which the testbench raises and this handles

The PlayStation's R3000A is little-endian and has no TLB, no FPU, and a
4 kB scratchpad it calls a cache. The address map here is the console's:
program in the BIOS window at $BFC00000 (KSEG1, uncached), RAM at $00000000
seen also through KSEG0/KSEG1, results in RAM, exception vector at
$BFC00180 because BEV is left set -- so the handler can live in the ROM.

Results at RAM $1000:

    $1000  the number of the first case that failed, 0 if none did
    $1004  how many checks ran
    $1008  what the processor produced
    $100C  what it should have produced
    $1010  count of exceptions taken (the handler increments it)
    $1014  the last Cause the handler saw
    $1018  the last EPC the handler saw
"""
import sys
import os
import random

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))   # mipsasm
from mipsasm import *                                        # noqa: E402
from mipsasm import _s16                                     # noqa: E402
from gte import GTE                                          # noqa: E402

ROM     = 0xBFC00000
RESULT  = 0x00001000
COUNT   = 0x00001004
ACTUAL  = 0x00001008
WANTED  = 0x0000100C
EXCN    = 0x00001010
EXCAUSE = 0x00001014
EXEPC   = 0x00001018
SCRATCH = 0x00002000      # memory the load/store cases work in
STACK   = 0x00010000

M = 0xFFFFFFFF


def s32(v):
    v &= M
    return v - (1 << 32) if v & 0x80000000 else v


def u32(v):
    return v & M


# --- the reference model: one function per instruction ---------------------------

def m_add(a, b):
    r = s32(a) + s32(b)
    if r > 0x7FFFFFFF or r < -0x80000000:
        return None                      # overflow: traps, rd unchanged
    return u32(r)

def m_sub(a, b):
    r = s32(a) - s32(b)
    if r > 0x7FFFFFFF or r < -0x80000000:
        return None
    return u32(r)

def m_addu(a, b): return u32(a + b)
def m_subu(a, b): return u32(a - b)
def m_and(a, b):  return a & b
def m_or(a, b):   return a | b
def m_xor(a, b):  return a ^ b
def m_nor(a, b):  return u32(~(a | b))
def m_slt(a, b):  return 1 if s32(a) < s32(b) else 0
def m_sltu(a, b): return 1 if u32(a) < u32(b) else 0

def m_sll(v, n):  return u32(v << (n & 31))
def m_srl(v, n):  return u32(v) >> (n & 31)
def m_sra(v, n):  return u32(s32(v) >> (n & 31))

def m_mult(a, b):
    p = s32(a) * s32(b)
    return u32(p >> 32), u32(p)          # HI, LO

def m_multu(a, b):
    p = u32(a) * u32(b)
    return u32(p >> 32), u32(p)

def m_div(a, b):
    a, b = s32(a), s32(b)
    if b == 0:
        return u32(a), (M if a >= 0 else 1)          # HI = rs, LO = -1 or +1
    if a == -0x80000000 and b == -1:
        return 0, 0x80000000
    q = abs(a) // abs(b)
    if (a < 0) != (b < 0):
        q = -q
    r = a - q * b
    return u32(r), u32(q)

def m_divu(a, b):
    a, b = u32(a), u32(b)
    if b == 0:
        return a, M
    return a % b, a // b


# --- the sweep ------------------------------------------------------------------------

# Where the flags and the carries change: zero, one, minus one, the two ends of
# the signed range, and two middles that are not special at all.
EDGES = [0x00000000, 0x00000001, 0xFFFFFFFF, 0x7FFFFFFF, 0x80000000,
         0x12345678, 0xDEADBEEF, 0x0000FFFF, 0xFFFF0000]
IMMS  = [0x0000, 0x0001, 0xFFFF, 0x7FFF, 0x8000, 0x1234, 0xABCD]
SHIFTS = [0, 1, 7, 15, 16, 31]


class Gen:
    def __init__(self):
        self.a = Asm(org=ROM)
        self.case = 0

    # --- the harness --------------------------------------------------------------
    def check(self, reg, expected):
        """Compare `reg` with a constant; on mismatch record and stop."""
        self.case += 1
        a = self.a
        a.li(AT, expected)
        a.bne(reg, AT, 'fail_%d' % self.case)
        a.nop()
        # The failure path is out of line, so the passing path stays a straight
        # run and the branch predictor -- there is none, but the reader -- is
        # not confused by a jump around every case.
        self.fails = getattr(self, 'fails', [])
        self.fails.append((self.case, reg, expected))

    def emit_fail_stubs(self):
        a = self.a
        for case, reg, expected in self.fails:
            a.label('fail_%d' % case)
            a.li(T8, case)
            a.or_(T9, reg, ZERO)          # the actual value, before AT is reused
            a.li(AT, expected)
            a.j('fail')
            a.nop()


    # --- the depth FIFO across a SEQUENCE of commands ------------------------------
    #
    # A PlayStation has no depth buffer. Polygons are painted back to front in
    # the order the ordering table holds them, and the bucket a polygon goes in
    # is OTZ, which AVSZ3 works out from the SZ depth FIFO that RTPS pushes.
    # Get the FIFO wrong and a box paints its far face over its near one --
    # which on screen is the sides of every box and character swapping which is
    # closer to the camera, and flipping again the next frame.
    #
    # tb_gte cannot catch that: it loads the registers and runs ONE command, so
    # the FIFO's shifting from one RTPS to the next is never exercised. This
    # runs real sequences -- three RTPS then AVSZ3, four then AVSZ4, and RTPT
    # which pushes three at once -- and checks OTZ and the whole FIFO against
    # the model in tools/ps1/gte.py.
    def gte_fifo(self):
        a = self.a
        for case in range(6):
            rnd = random.Random(7000 + case)
            g = GTE()
            d = [0] * 32
            c = [0] * 32
            for n in range(3):
                d[2*n]     = (rnd.randint(-0x400, 0x400) & 0xFFFF) | ((rnd.randint(-0x400, 0x400) & 0xFFFF) << 16)
                d[2*n + 1] = rnd.randint(-0x800, 0x800) & 0xFFFF
            for i in range(9):
                c[i] = (rnd.randint(-0x1800, 0x1800) & 0xFFFF) | ((rnd.randint(-0x1800, 0x1800) & 0xFFFF) << 16)
            for i in (5, 6, 7):
                c[i] = rnd.randint(-0x10000, 0x10000) & 0xFFFFFFFF
            c[24] = rnd.randint(-0x100000, 0x100000) & 0xFFFFFFFF
            c[25] = rnd.randint(-0x100000, 0x100000) & 0xFFFFFFFF
            c[26] = rnd.randint(0x100, 0x400)
            c[27] = rnd.randint(-0x100, 0x100) & 0xFFFF
            c[28] = rnd.randint(-0x100000, 0x100000) & 0xFFFFFFFF
            c[29] = 0x0155                      # ZSF3 = 1/3
            c[30] = 0x0100                      # ZSF4 = 1/4
            seq = [0x0180001, 0x0180001, 0x0180001, 0x0158002D] if case % 2 == 0                   else [0x0280030, 0x0180001, 0x015A002E]
            for i in range(32):
                if i not in self.GTE_SKIP:
                    g.write_data(i, d[i])
            for i in range(32):
                g.write_ctrl(i, c[i])
            for wrd in seq:
                g.op(wrd)
            self._gte_load(d, c)
            for wrd in seq:
                a.cop2(wrd)
                a.nop(); a.nop()
            for r in (16, 17, 18, 19, 7):        # SZ0..SZ3 and OTZ
                a.mfc2(T2, r); a.nop()
                self.check(T2, g.read_data(r))

    # --- the depth FIFO across a SEQUENCE of commands ------------------------------
    #
    # A PlayStation has no depth buffer. Polygons are painted back to front in
    # the order the ordering table holds them, and which bucket a polygon goes
    # into is OTZ -- which AVSZ3 works out from the SZ depth FIFO that RTPS
    # pushes. Get that FIFO wrong and a box paints its far face over its near
    # one, so the sides of boxes and characters swap which is closer to the
    # camera.
    #
    # tb_gte cannot catch it: it loads the registers and runs ONE command, so
    # the FIFO shifting from one RTPS to the next is never exercised. This runs
    # real sequences and checks SZ0..SZ3 and OTZ against tools/ps1/gte.py.
    def gte_fifo(self):
        a = self.a
        done = 0
        seed = 7000
        while done < 5 and seed < 7200:
            seed += 1
            rnd = random.Random(seed)
            d = [0] * 32; c = [0] * 32
            for n in range(3):
                d[2*n]     = (rnd.randint(-0x400, 0x400) & 0xFFFF) | ((rnd.randint(-0x400, 0x400) & 0xFFFF) << 16)
                d[2*n + 1] = rnd.randint(-0x800, 0x800) & 0xFFFF
            for i in range(9):
                c[i] = (rnd.randint(-0x1800, 0x1800) & 0xFFFF) | ((rnd.randint(-0x1800, 0x1800) & 0xFFFF) << 16)
            for i in (5, 6, 7):
                c[i] = rnd.randint(-0x10000, 0x10000) & 0xFFFFFFFF
            c[26] = rnd.randint(0x100, 0x400)
            c[29] = 0x0155; c[30] = 0x0100
            seq = ([0x0180001, 0x0180001, 0x0180001, 0x0158002D] if done % 2 == 0
                   else [0x0280030, 0x0180001, 0x015A002E])
            g = GTE()
            for i in range(32):
                if i not in self.GTE_SKIP:
                    g.write_data(i, d[i])
            for i in range(32):
                g.write_ctrl(i, c[i])
            for wrd in seq:
                g.op(wrd)
            if g.read_data(7) == 0:
                continue                      # a case that proves nothing
            done += 1
            self._gte_load(d, c)
            for wrd in seq:
                a.cop2(wrd); a.nop(); a.nop()
            # SXY0..SXY2 are the SAME kind of FIFO and carry the projected
            # CORNERS: a game runs RTPS three times and reads these three back
            # as its triangle. Off by one here and vertices take each other's
            # positions, which mirrors a face -- the right side of a box drawn
            # where the left should be.
            for r in (12, 13, 14, 16, 17, 18, 19, 7):   # SXY0..2, SZ0..3, OTZ
                a.mfc2(T2, r); a.nop()
                self.check(T2, g.read_data(r))
            # NCLIP on what that sequence left in the SXY FIFO. Its SIGN is how
            # a game decides whether a face points at the camera; get it wrong
            # and the back faces of a box are drawn instead of the front ones,
            # so the far side appears to be the near one.
            g.op(0x0140006)
            a.cop2(0x0140006); a.nop(); a.nop()
            a.mfc2(T2, 24); a.nop()                 # MAC0 = the cross product
            self.check(T2, g.read_data(24))

    # --- reading a GTE result the instruction after the command --------------------
    #
    # A game builds its display list straight out of the GTE: RTPS, then the
    # projected vertex is moved or stored out of it, often with nothing in
    # between. If `busy` fell a clock before the last result register was
    # written, that read would take the PREVIOUS command's value -- and since
    # it only bites when the read lands in that one clock, it would spoil a
    # small fraction of polygons and leave the rest perfect. That is the shape
    # of the runaway vertex seen on the board, so every result register is read
    # here at every distance from the command, including none at all, through
    # both ways a program can get a value out: MFC2 and SWC2.
    #
    # The expected values come from tools/ps1/gte.py, the same model tb_gte checks
    # the GTE itself against, so a failure here is the processor's timing and
    # not the arithmetic.
    GTE_READ = [9, 10, 11, 12, 13, 14, 19, 24, 25, 26, 27]   # IR1-3, SXY0-2, SZ3, MAC0-3
    GTE_SKIP = {29, 31}                                       # derived / read-only

    def _gte_state(self, seed):
        """A determined GTE state and a command, and what the model makes of it."""
        rnd = random.Random(seed)
        d = [0] * 32
        c = [0] * 32
        for n in range(3):                                    # V0..V2, a few hundred out
            d[2 * n] = (rnd.randint(-0x400, 0x400) & 0xFFFF) | ((rnd.randint(-0x400, 0x400) & 0xFFFF) << 16)
            d[2 * n + 1] = rnd.randint(-0x800, 0x800) & 0xFFFF
        d[6] = rnd.getrandbits(32)                            # RGBC
        d[8] = rnd.randint(0, 0x1000)                         # IR0
        for i in (9, 10, 11):
            d[i] = rnd.randint(-0x1000, 0x1000) & 0xFFFF
        for i in range(9):                                    # the rotation matrix, near 1.0
            c[i] = (rnd.randint(-0x1800, 0x1800) & 0xFFFF) | ((rnd.randint(-0x1800, 0x1800) & 0xFFFF) << 16)
        for i in (5, 6, 7):
            c[i] = rnd.randint(-0x10000, 0x10000) & 0xFFFFFFFF
        c[24] = rnd.randint(-0x100000, 0x100000) & 0xFFFFFFFF  # OFX
        c[25] = rnd.randint(-0x100000, 0x100000) & 0xFFFFFFFF  # OFY
        c[26] = rnd.randint(0x100, 0x400)                      # H
        c[27] = rnd.randint(-0x100, 0x100) & 0xFFFF            # DQA
        c[28] = rnd.randint(-0x100000, 0x100000) & 0xFFFFFFFF  # DQB
        word = rnd.choice([0x0180001, 0x0280030, 0x1400006, 0x0a00428])  # RTPS, RTPT, NCLIP, SQR
        g = GTE()
        for i in range(32):
            if i not in self.GTE_SKIP:
                g.write_data(i, d[i])
        for i in range(32):
            g.write_ctrl(i, c[i])
        g.op(word)
        return d, c, word, [g.read_data(i) for i in range(32)]

    def _gte_load(self, d, c):
        a = self.a
        for i in range(32):
            if i in self.GTE_SKIP:
                continue
            a.li(T0, d[i]); a.mtc2(T0, i)
        for i in range(32):
            a.li(T0, c[i]); a.ctc2(T0, i)

    def gte_timing(self):
        a = self.a
        a.li(S0, SCRATCH)
        for case in range(4):
            d, c, word, out = self._gte_state(1000 + case)
            for delay in range(4):
                # rotate which register is read FIRST, so each one is read at
                # every distance from the command across the four cases
                regs = self.GTE_READ[case:] + self.GTE_READ[:case]
                # out of the GTE with MFC2
                self._gte_load(d, c)
                a.cop2(word)
                for _ in range(delay):
                    a.nop()
                for r in regs:
                    a.mfc2(T2, r); a.nop(); self.check(T2, out[r])
                # out of the GTE with SWC2, straight to memory, the way libgte
                # writes a vertex into a display list
                self._gte_load(d, c)
                a.cop2(word)
                for _ in range(delay):
                    a.nop()
                a.swc2(regs[0], 0x30, S0)
                a.lw(T2, 0x30, S0); a.nop(); self.check(T2, out[regs[0]])

    # --- sections ----------------------------------------------------------------
    def alu_reg(self):
        a = self.a
        ops = [('add', m_add, a.add), ('addu', m_addu, a.addu),
               ('sub', m_sub, a.sub), ('subu', m_subu, a.subu),
               ('and', m_and, a.and_), ('or', m_or, a.or_),
               ('xor', m_xor, a.xor), ('nor', m_nor, a.nor),
               ('slt', m_slt, a.slt), ('sltu', m_sltu, a.sltu)]
        for name, model, emit in ops:
            for x in EDGES:
                for y in EDGES:
                    want = model(x, y)
                    if want is None:
                        continue         # overflow cases are tested separately
                    a.li(T0, x); a.li(T1, y)
                    a.li(T2, 0xC0FFEE00)     # a destination that must change
                    emit(T2, T0, T1)
                    self.check(T2, want)

    def alu_imm(self):
        a = self.a
        for x in EDGES:
            for imm in IMMS:
                se = u32(_s16(imm))
                a.li(T0, x); a.addiu(T2, T0, imm); self.check(T2, m_addu(x, se))
                a.li(T0, x); a.slti(T2, T0, imm);  self.check(T2, m_slt(x, se))
                a.li(T0, x); a.sltiu(T2, T0, imm); self.check(T2, m_sltu(x, se))
                a.li(T0, x); a.andi(T2, T0, imm);  self.check(T2, x & imm)
                a.li(T0, x); a.ori(T2, T0, imm);   self.check(T2, x | imm)
                a.li(T0, x); a.xori(T2, T0, imm);  self.check(T2, x ^ imm)
                want = m_add(x, se)
                if want is not None:
                    a.li(T0, x); a.addi(T2, T0, imm); self.check(T2, want)
            a.lui(T2, x & 0xFFFF); self.check(T2, (x & 0xFFFF) << 16)

    def shifts(self):
        a = self.a
        for x in EDGES:
            for n in SHIFTS:
                a.li(T0, x); a.sll(T2, T0, n); self.check(T2, m_sll(x, n))
                a.li(T0, x); a.srl(T2, T0, n); self.check(T2, m_srl(x, n))
                a.li(T0, x); a.sra(T2, T0, n); self.check(T2, m_sra(x, n))
            # by register: only the low five bits count, so 33 shifts by 1
            for n in [3, 33, 0xFFFFFFFF, 0x100]:
                a.li(T0, x); a.li(T1, n)
                a.sllv(T2, T0, T1); self.check(T2, m_sll(x, n))
                a.li(T0, x); a.li(T1, n)
                a.srlv(T2, T0, T1); self.check(T2, m_srl(x, n))
                a.li(T0, x); a.li(T1, n)
                a.srav(T2, T0, T1); self.check(T2, m_sra(x, n))

    def muldiv(self):
        a = self.a
        pairs = [(x, y) for x in EDGES for y in EDGES]
        for x, y in pairs:
            hi, lo = m_mult(x, y)
            a.li(T0, x); a.li(T1, y); a.mult(T0, T1)
            a.mfhi(T2); self.check(T2, hi)
            a.mflo(T2); self.check(T2, lo)
            hi, lo = m_multu(x, y)
            a.li(T0, x); a.li(T1, y); a.multu(T0, T1)
            a.mfhi(T2); self.check(T2, hi)
            a.mflo(T2); self.check(T2, lo)
        for x, y in pairs + [(0x80000000, 0xFFFFFFFF), (7, 0), (0xFFFFFFF9, 0)]:
            hi, lo = m_div(x, y)
            a.li(T0, x); a.li(T1, y); a.div(T0, T1)
            a.mfhi(T2); self.check(T2, hi)
            a.mflo(T2); self.check(T2, lo)
            hi, lo = m_divu(x, y)
            a.li(T0, x); a.li(T1, y); a.divu(T0, T1)
            a.mfhi(T2); self.check(T2, hi)
            a.mflo(T2); self.check(T2, lo)
        # MTHI/MTLO round trip
        a.li(T0, 0x5A5A5A5A); a.mthi(T0); a.li(T0, 0xA5A5A5A5); a.mtlo(T0)
        a.mfhi(T2); self.check(T2, 0x5A5A5A5A)
        a.mflo(T2); self.check(T2, 0xA5A5A5A5)
        # the multiplier and divider are pipelined: whatever touches HI/LO
        # while one is still landing has to wait for it, in every order
        hi, lo = m_mult(0x12345678, 0x9ABCDEF0)
        a.li(T0, 0x12345678); a.li(T1, 0x9ABCDEF0); a.mult(T0, T1); a.mult(T1, T0)   # back to back
        a.mfhi(T2); self.check(T2, hi); a.mflo(T2); self.check(T2, lo)
        hi, lo = m_div(0x12345678, 0x9ABCDEF0)
        a.mult(T0, T1); a.div(T0, T1)                                                # DIV right after MULT
        a.mfhi(T2); self.check(T2, hi); a.mflo(T2); self.check(T2, lo)
        hi, lo = m_multu(0x12345678, 0x9ABCDEF0)
        a.div(T0, T1); a.multu(T0, T1)                                               # MULTU right after DIV
        a.mfhi(T2); self.check(T2, hi); a.mflo(T2); self.check(T2, lo)
        a.mult(T0, T1); a.li(T3, 0x77777777); a.mthi(T3)                            # MTHI right after MULT
        a.mfhi(T2); self.check(T2, 0x77777777); a.mflo(T2); self.check(T2, lo)
        hi, lo = m_mult(0x12345678, 0x9ABCDEF0)
        a.mult(T0, T1); a.mtlo(T3)                                                   # MTLO right after MULT
        a.mflo(T2); self.check(T2, 0x77777777); a.mfhi(T2); self.check(T2, hi)
        a.li(T0, 7); a.li(T1, 0); a.mult(T0, T1); a.div(T0, T1)                     # divide by zero right after MULT
        hi, lo = m_div(7, 0)
        a.mfhi(T2); self.check(T2, hi); a.mflo(T2); self.check(T2, lo)

    def memory(self):
        a = self.a
        a.li(S0, SCRATCH)
        # A known word, then read it every way. Little-endian: byte 0 is $78.
        a.li(T0, 0x12345678); a.sw(T0, 0, S0)
        a.li(T0, 0xFEDCBA98); a.sw(T0, 4, S0)
        a.lw(T2, 0, S0);  a.nop(); self.check(T2, 0x12345678)
        a.lb(T2, 0, S0);  a.nop(); self.check(T2, 0x78)
        a.lb(T2, 1, S0);  a.nop(); self.check(T2, 0x56)
        a.lb(T2, 4, S0);  a.nop(); self.check(T2, 0xFFFFFF98)   # sign-extended
        a.lbu(T2, 4, S0); a.nop(); self.check(T2, 0x98)
        a.lh(T2, 0, S0);  a.nop(); self.check(T2, 0x5678)
        a.lh(T2, 6, S0);  a.nop(); self.check(T2, 0xFFFFFEDC)
        a.lhu(T2, 6, S0); a.nop(); self.check(T2, 0xFEDC)
        a.lh(T2, 2, S0);  a.nop(); self.check(T2, 0x1234)
        # negative offsets
        a.addiu(S1, S0, 8)
        a.lw(T2, -8, S1); a.nop(); self.check(T2, 0x12345678)
        a.lbu(T2, -1, S1); a.nop(); self.check(T2, 0xFE)
        # byte and half stores must not touch their neighbours
        a.li(T0, 0xFFFFFFFF); a.sw(T0, 8, S0)
        a.li(T0, 0x11); a.sb(T0, 9, S0)
        a.lw(T2, 8, S0); a.nop(); self.check(T2, 0xFFFF11FF)
        a.li(T0, 0x2222); a.sh(T0, 10, S0)
        a.lw(T2, 8, S0); a.nop(); self.check(T2, 0x222211FF)
        # the unaligned four, every alignment, little-endian rules
        word = 0x12345678
        for off in range(4):
            a.li(T0, word); a.sw(T0, 0, S0)
            a.li(T0, 0xFEDCBA98); a.sw(T0, 4, S0)
            a.li(T2, 0xAABBCCDD)
            a.lwl(T2, off, S0); a.nop()
            self.check(T2, self._lwl(0xAABBCCDD, word, off))
            a.li(T2, 0xAABBCCDD)
            a.lwr(T2, off, S0); a.nop()
            self.check(T2, self._lwr(0xAABBCCDD, word, off))
            a.li(T0, word); a.sw(T0, 0, S0)
            a.li(T2, 0xAABBCCDD); a.swl(T2, off, S0)
            a.lw(T3, 0, S0); a.nop()
            self.check(T3, self._swl(word, 0xAABBCCDD, off))
            a.li(T0, word); a.sw(T0, 0, S0)
            a.li(T2, 0xAABBCCDD); a.swr(T2, off, S0)
            a.lw(T3, 0, S0); a.nop()
            self.check(T3, self._swr(word, 0xAABBCCDD, off))
        # the pair a compiler emits for an unaligned word, back to back with no
        # slot between them: the LWR merges into the LWL's result, which has
        # not reached the register yet -- the chip forwards it. Same for the
        # store pair. An ISO directory's extents sit at odd offsets, so a
        # game's file lookup is made of nothing else.
        buf = (0xFEDCBA98 << 32) | 0x12345678
        for off in range(4):
            a.li(T0, 0x12345678); a.sw(T0, 0, S0); a.li(T0, 0xFEDCBA98); a.sw(T0, 4, S0)
            a.li(T2, 0xAABBCCDD)
            a.lwl(T2, off + 3, S0); a.lwr(T2, off, S0); a.nop()
            self.check(T2, (buf >> (8 * off)) & 0xFFFFFFFF)
            a.li(T2, 0x0BADF00D); a.swl(T2, off + 3, S0); a.swr(T2, off, S0)
            a.lw(T3, 0, S0); a.lw(T4, 4, S0); a.nop()
            want = (buf & ~(0xFFFFFFFF << (8 * off))) | (0x0BADF00D << (8 * off))
            self.check(T3, want & 0xFFFFFFFF); self.check(T4, (want >> 32) & 0xFFFFFFFF)
        # the GTE's leading-count register, read back the way libgte's square root
        # does it (two slots), after a fresh write and right behind a GTE command
        for v, want in ((0x00000001, 31), (0x00800000, 8), (0x0000003E, 26), (0xFFFFFF80, 25), (0x80000000, 1), (0, 32), (0xFFFFFFFF, 32), (0x12345678, 3)):
            a.li(T0, v); a.mtc2(T0, 30); a.nop(); a.nop(); a.mfc2(T2, 31); a.nop(); self.check(T2, want)
            a.cop2(0x0400012); a.li(T0, v); a.mtc2(T0, 30); a.nop(); a.nop(); a.mfc2(T2, 31); a.nop(); self.check(T2, want)   # NCLIP running
        # A move IN right behind a move OUT, as libgte's MulMatrix0 does it (mtc2 t2,d2 / mfc2 v1,d9):
        # the write is registered and reaches the GTE a clock later, when the read's register number
        # is on the shared lines -- the write landed in the register being read. Gran Turismo 2's
        # matrices lost their middle row and column to it, and every vertex fell on one line.
        a.li(T0, 0x1111); a.mtc2(T0, 9); a.nop(); a.nop()                    # IR1 = 0x1111
        a.li(T0, 0x10000000); a.mtc2(T0, 2); a.mfc2(T2, 9); a.nop()          # VXY1, then read IR1 at once
        self.check(T2, 0x1111)
        a.mfc2(T2, 2); a.nop(); self.check(T2, 0x10000000)                   # ...and VXY1 has its value
        a.mfc2(T2, 9); a.nop(); self.check(T2, 0x1111)                       # ...and IR1 kept its own
        a.li(T0, 0x00ABCDEF); a.ctc2(T0, 5); a.nop(); a.nop()                # TRX
        a.li(T0, 0x02000300); a.ctc2(T0, 0); a.cfc2(T2, 5); a.nop()          # RT11RT12, then read TRX at once
        self.check(T2, 0x00ABCDEF)
        a.cfc2(T2, 0); a.nop(); self.check(T2, 0x02000300)
        a.li(T0, 0x7654321); a.sw(T0, 0x40, S0); a.li(T0, 0x2222); a.mtc2(T0, 10); a.nop(); a.nop()
        a.lwc2(4, 0x40, S0); a.mfc2(T2, 10); a.nop(); self.check(T2, 0x2222)  # LWC2 VXY2, then read IR2
        a.mfc2(T2, 4); a.nop(); self.check(T2, 0x7654321)
        # the same RAM through KSEG0 and KSEG1 is the same RAM
        a.li(T0, 0x0BADF00D); a.sw(T0, 0x20, S0)
        a.li(S1, SCRATCH | 0x80000000); a.lw(T2, 0x20, S1); a.nop(); self.check(T2, 0x0BADF00D)
        a.li(S1, SCRATCH | 0xA0000000); a.lw(T2, 0x20, S1); a.nop(); self.check(T2, 0x0BADF00D)

    @staticmethod
    def _lwl(rt, w, off):
        return [(rt & 0x00FFFFFF) | u32(w << 24), (rt & 0x0000FFFF) | u32(w << 16),
                (rt & 0x000000FF) | u32(w << 8), w][off]

    @staticmethod
    def _lwr(rt, w, off):
        return [w, (rt & 0xFF000000) | (w >> 8), (rt & 0xFFFF0000) | (w >> 16),
                (rt & 0xFFFFFF00) | (w >> 24)][off]

    @staticmethod
    def _swl(mem, rt, off):
        return [(mem & 0xFFFFFF00) | (rt >> 24), (mem & 0xFFFF0000) | (rt >> 16),
                (mem & 0xFF000000) | (rt >> 8), rt][off]

    @staticmethod
    def _swr(mem, rt, off):
        return [rt, (mem & 0x000000FF) | u32(rt << 8), (mem & 0x0000FFFF) | u32(rt << 16),
                (mem & 0x00FFFFFF) | u32(rt << 24)][off]

    def load_delay(self):
        a = self.a
        a.li(S0, SCRATCH)
        a.li(T0, 0x11111111); a.sw(T0, 0, S0)
        a.li(T2, 0x22222222)
        a.lw(T2, 0, S0)
        a.or_(T3, T2, ZERO)           # in the delay slot: sees the OLD T2
        a.or_(T4, T2, ZERO)           # one later: sees the load
        self.check(T3, 0x22222222)
        self.check(T4, 0x11111111)
        # The slot instruction WRITES the loaded register: its write is later in
        # program order and wins on the chip (the load's writeback precedes the
        # slot's). `lw ra,..; jal` is the BIOS shell's idiom; getting it wrong
        # returned a callee two levels up.
        a.li(T2, 5)
        a.lw(T2, 0, S0)
        a.addiu(T2, T2, 1)            # slot: old T2 + 1, and this value must stay
        a.nop()
        self.check(T2, 6)
        a.j('ld_skip'); a.nop()
        a.label('ld_f'); a.jr(RA); a.nop()
        a.label('ld_skip')
        a.lw(RA, 0, S0)               # ra <- 0x11111111 lands... but the jal's link wins
        a.jal('ld_f'); a.nop()
        a.label('ld_ret')
        self.check(RA, a.labels['ld_ret'])

    def branches(self):
        a = self.a
        n = 0
        def taken(emit, x, y, expect_taken):
            nonlocal n
            n += 1
            a.li(T0, x); a.li(T1, y)
            a.li(T2, 0)
            emit('br_t%d' % n)
            a.addiu(T2, T2, 1)           # delay slot: ALWAYS runs
            a.addiu(T2, T2, 0x10)        # skipped when taken
            a.label('br_t%d' % n)
            a.addiu(T2, T2, 0x100)
            self.check(T2, 0x101 if expect_taken else 0x111)
        for x, y in [(1, 1), (1, 2), (0xFFFFFFFF, 0xFFFFFFFF), (0x80000000, 0)]:
            taken(lambda l: a.beq(T0, T1, l), x, y, x == y)
            taken(lambda l: a.bne(T0, T1, l), x, y, x != y)
        for x in EDGES:
            taken(lambda l: a.blez(T0, l), x, 0, s32(x) <= 0)
            taken(lambda l: a.bgtz(T0, l), x, 0, s32(x) > 0)
            taken(lambda l: a.bltz(T0, l), x, 0, s32(x) < 0)
            taken(lambda l: a.bgez(T0, l), x, 0, s32(x) >= 0)
        # the link register is the branch's own address + 8
        a.label('link_site')
        a.jal('link_target'); a.nop()
        a.label('link_back')
        self.check(RA, a.labels['link_site'] + 8)
        # jalr and the AL branches
        a.la(T0, 'jr_target')
        a.jalr(T0); a.nop()
        a.label('jr_back')
        a.li(T2, 0)
        a.bgezal(ZERO, 'al_target'); a.nop()
        a.label('al_back')
        self.check(T2, 0x77)

    def branch_targets(self):
        a = self.a
        a.label('link_target')
        a.jr(RA); a.nop()
        a.label('jr_target')
        a.jr(RA); a.nop()
        a.label('al_target')
        a.li(T2, 0x77)
        a.jr(RA); a.nop()

    def exceptions(self):
        a = self.a
        a.li(S0, EXCN)
        # overflow on ADD: traps, ExcCode 12, destination untouched
        a.li(T2, 0x55555555)
        a.li(T0, 0x7FFFFFFF); a.li(T1, 1)
        a.add(T2, T0, T1)
        a.nop()
        self.check(T2, 0x55555555)
        a.lw(T3, EXCAUSE - EXCN, S0); a.nop()
        a.andi(T3, T3, 0x7C); self.check(T3, 12 << 2)
        # ADDI overflow likewise
        a.li(T2, 0x66666666)
        a.li(T0, 0x80000000); a.addi(T2, T0, -1)
        a.nop()
        self.check(T2, 0x66666666)
        # SYSCALL: ExcCode 8, EPC is its own address, RFE lands after it
        a.la(T4, 'sys_site')
        a.label('sys_site')
        a.syscall()
        a.li(T2, 0x99)
        self.check(T2, 0x99)
        a.lw(T3, EXCAUSE - EXCN, S0); a.nop()
        a.andi(T3, T3, 0x7C); self.check(T3, 8 << 2)
        a.lw(T3, EXEPC - EXCN, S0); a.nop()
        self.check(T3, a.labels['sys_site'])
        # BREAK: ExcCode 9
        a.break_()
        a.lw(T3, EXCAUSE - EXCN, S0); a.nop()
        a.andi(T3, T3, 0x7C); self.check(T3, 9 << 2)
        # misaligned LW: address error on load, ExcCode 4, BadVaddr = the address
        a.li(S1, SCRATCH + 2)
        a.li(T2, 0x44444444)
        a.lw(T2, 0, S1)
        a.nop()
        self.check(T2, 0x44444444)
        a.lw(T3, EXCAUSE - EXCN, S0); a.nop()
        a.andi(T3, T3, 0x7C); self.check(T3, 4 << 2)
        a.mfc0(T3, C0_BADVADDR); self.check(T3, SCRATCH + 2)
        # an exception in a branch delay slot: EPC is the BRANCH, Cause.BD set
        a.la(T4, 'bd_site')
        a.label('bd_site')
        a.beq(ZERO, ZERO, 'bd_after')
        a.syscall()                       # in the slot
        a.label('bd_after')
        a.lw(T3, EXEPC - EXCN, S0); a.nop()
        self.check(T3, a.labels['bd_site'])
        a.lw(T3, EXCAUSE - EXCN, S0); a.nop()
        a.srl(T3, T3, 31); self.check(T3, 1)
        # how many exceptions so far: add, addi, syscall, break, lw, syscall
        a.lw(T3, 0, S0); a.nop(); self.check(T3, 6)

    def interrupt(self):
        """Enable interrupts, ask the testbench for one, wait for it."""
        a = self.a
        a.li(S0, EXCN)
        # SR: IEc=1, IM all set (bits 8-15), BEV kept
        a.li(T0, 0x4040FF01); a.mtc0(T0, C0_SR)
        a.li(T0, 0xDEAD0001)              # the testbench watches for this store
        a.li(T1, SCRATCH + 0x40); a.sw(T0, 0, T1)
        a.li(T2, 0)
        a.label('irq_wait')
        a.lw(T3, 0, S0); a.nop()          # exceptions taken so far
        a.li(T4, 7)
        a.bne(T3, T4, 'irq_wait')
        a.addiu(T2, T2, 1)
        a.lw(T3, EXCAUSE - EXCN, S0); a.nop()
        a.andi(T3, T3, 0x7C); self.check(T3, 0)      # ExcCode 0 = Int
        a.li(T0, 0x40400000); a.mtc0(T0, C0_SR)      # interrupts off again

    def handler(self):
        """At ROM+$180: count it, record Cause and EPC, step past, return."""
        a = self.a
        while a.pc < ROM + 0x180:
            a.nop()
        assert a.pc == ROM + 0x180
        a.label('exc')
        a.li(K0, EXCN)
        a.lw(K1, 0, K0); a.nop()
        a.addiu(K1, K1, 1); a.sw(K1, 0, K0)
        a.mfc0(K1, C0_CAUSE); a.sw(K1, EXCAUSE - EXCN, K0)
        a.mfc0(K1, C0_EPC);   a.sw(K1, EXEPC - EXCN, K0)
        # An interrupt returns to EPC itself; anything else steps past the
        # instruction that caused it -- or past the branch, if it was in a
        # delay slot, since re-executing the branch re-executes the slot.
        a.mfc0(K1, C0_CAUSE)
        a.andi(K1, K1, 0x7C)
        a.beq(K1, ZERO, 'exc_ret'); a.nop()
        a.mfc0(K1, C0_EPC)
        a.mfc0(K0, C0_CAUSE)
        a.bltz(K0, 'exc_bd'); a.nop()
        a.addiu(K1, K1, 4)
        a.j('exc_go'); a.nop()
        a.label('exc_bd')
        a.addiu(K1, K1, 8)
        a.label('exc_go')
        a.jr(K1)
        a.rfe()
        a.label('exc_ret')
        a.mfc0(K1, C0_EPC)
        a.jr(K1)
        a.rfe()

    def build(self):
        a = self.a
        a.label('reset')
        a.j('main'); a.nop()
        self.handler()
        a.label('main')
        a.li(SP, STACK)
        a.li(T0, 0); a.li(T1, RESULT)
        for off in range(0, 0x1C, 4):
            a.sw(ZERO, off, T1)
        a.li(T0, 0x40400000); a.mtc0(T0, C0_SR)      # BEV=1, COP2 (the GTE) usable, interrupts off
        self.alu_reg()
        self.alu_imm()
        self.shifts()
        self.muldiv()
        self.memory()
        self.load_delay()
        self.branches()
        self.gte_timing()
        self.gte_fifo()
        self.gte_fifo()
        self.exceptions()
        self.interrupt()
        # all passed
        a.li(T0, RESULT)
        a.sw(ZERO, 0, T0)
        a.li(T1, self.case); a.sw(T1, 4, T0)
        a.label('done')
        a.j('done'); a.nop()
        # failure: RESULT = case, COUNT = case, ACTUAL = T9, WANTED = AT
        a.label('fail')
        a.li(T0, RESULT)
        a.sw(T8, 0, T0); a.sw(T8, 4, T0); a.sw(T9, 8, T0); a.sw(AT, 12, T0)
        a.label('halt')
        a.j('halt'); a.nop()
        self.branch_targets()
        self.emit_fail_stubs()
        return a.words()



def main():
    out = sys.argv[1] if len(sys.argv) > 1 else 'sim/roms/mips/mipstest.hex'
    g = Gen()
    words = g.build()
    os.makedirs(os.path.dirname(out) or '.', exist_ok=True)
    write_hex(words, out)
    print('%s: %d words (%d kB), %d checks' % (out, len(words), len(words) * 4 // 1024, g.case))


if __name__ == '__main__':
    main()
