"""A MIPS I assembler, for the R3000 in this tree.

    from mipsasm import *
    a = Asm(org=0xBFC00000)
    a.label('start')
    a.li(V0, 0x1234)
    a.sw(V0, 0, T0)
    a.j('start'); a.nop()
    words = a.words()

Everything the PlayStation's CPU executes in user code, plus COP0 moves and
RFE, and nothing else -- no floating point (the R3000A in a PlayStation has
none), no TLB instructions (it has no TLB). Written as a library rather than a
text assembler for the same reason m68kasm.py was: the test generator wants to
compute an expected result beside every instruction it emits, and that is a
Python loop, not a source file.

Delay slots are NOT filled for you. A branch or jump is followed by whatever
you emit next, exactly as on the chip, and forgetting `nop()` after `j` is the
first mistake everybody makes with this architecture. The generator fills its
own slots deliberately; hand-written code should too.
"""

# --- registers ------------------------------------------------------------
ZERO, AT, V0, V1, A0, A1, A2, A3 = range(8)
T0, T1, T2, T3, T4, T5, T6, T7 = range(8, 16)
S0, S1, S2, S3, S4, S5, S6, S7 = range(16, 24)
T8, T9, K0, K1, GP, SP, FP, RA = range(24, 32)

# COP0 registers the R3000A has
C0_BADVADDR, C0_SR, C0_CAUSE, C0_EPC, C0_PRID = 8, 12, 13, 14, 15


def _s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


class Asm:
    def __init__(self, org=0):
        self.org = org
        self.code = []          # 32-bit words
        self.labels = {}
        self.fixups = []        # (index, label, kind)

    # --- addresses -----------------------------------------------------------
    @property
    def pc(self):
        return self.org + 4 * len(self.code)

    def label(self, name):
        self.labels[name] = self.pc

    def _emit(self, w):
        self.code.append(w & 0xFFFFFFFF)

    def word(self, w):
        self._emit(w)

    def words(self):
        self._resolve()
        return list(self.code)

    def _resolve(self):
        for idx, name, kind in self.fixups:
            target = self.labels[name]
            here = self.org + 4 * idx
            if kind == 'branch':
                off = (target - (here + 4)) >> 2
                assert -0x8000 <= off < 0x8000, f'branch to {name} out of range'
                self.code[idx] = (self.code[idx] & 0xFFFF0000) | (off & 0xFFFF)
            elif kind == 'jump':
                assert (target & 0xF0000000) == ((here + 4) & 0xF0000000)
                self.code[idx] = (self.code[idx] & 0xFC000000) | ((target >> 2) & 0x03FFFFFF)
            elif kind == 'lo':
                self.code[idx] = (self.code[idx] & 0xFFFF0000) | (target & 0xFFFF)
            elif kind == 'hi':
                # lui/addiu pair: hi must compensate for a negative lo
                hi = ((target + 0x8000) >> 16) & 0xFFFF
                self.code[idx] = (self.code[idx] & 0xFFFF0000) | hi
        self.fixups = []

    # --- encoders ----------------------------------------------------------------
    def _r(self, op, rs, rt, rd, sh, fn):
        self._emit((op << 26) | (rs << 21) | (rt << 16) | (rd << 11) | (sh << 6) | fn)

    def _i(self, op, rs, rt, imm):
        self._emit((op << 26) | (rs << 21) | (rt << 16) | (imm & 0xFFFF))

    def _j(self, op, target):
        self._emit((op << 26) | ((target >> 2) & 0x03FFFFFF))

    # --- arithmetic, register ---------------------------------------------------
    def add(self, rd, rs, rt):   self._r(0, rs, rt, rd, 0, 0x20)
    def addu(self, rd, rs, rt):  self._r(0, rs, rt, rd, 0, 0x21)
    def sub(self, rd, rs, rt):   self._r(0, rs, rt, rd, 0, 0x22)
    def subu(self, rd, rs, rt):  self._r(0, rs, rt, rd, 0, 0x23)
    def and_(self, rd, rs, rt):  self._r(0, rs, rt, rd, 0, 0x24)
    def or_(self, rd, rs, rt):   self._r(0, rs, rt, rd, 0, 0x25)
    def xor(self, rd, rs, rt):   self._r(0, rs, rt, rd, 0, 0x26)
    def nor(self, rd, rs, rt):   self._r(0, rs, rt, rd, 0, 0x27)
    def slt(self, rd, rs, rt):   self._r(0, rs, rt, rd, 0, 0x2A)
    def sltu(self, rd, rs, rt):  self._r(0, rs, rt, rd, 0, 0x2B)

    # --- shifts ---------------------------------------------------------------------
    def sll(self, rd, rt, sh):   self._r(0, 0, rt, rd, sh & 31, 0x00)
    def srl(self, rd, rt, sh):   self._r(0, 0, rt, rd, sh & 31, 0x02)
    def sra(self, rd, rt, sh):   self._r(0, 0, rt, rd, sh & 31, 0x03)
    def sllv(self, rd, rt, rs):  self._r(0, rs, rt, rd, 0, 0x04)
    def srlv(self, rd, rt, rs):  self._r(0, rs, rt, rd, 0, 0x06)
    def srav(self, rd, rt, rs):  self._r(0, rs, rt, rd, 0, 0x07)
    def nop(self):               self._emit(0)

    # --- multiply / divide -----------------------------------------------------------
    def mult(self, rs, rt):      self._r(0, rs, rt, 0, 0, 0x18)
    def multu(self, rs, rt):     self._r(0, rs, rt, 0, 0, 0x19)
    def div(self, rs, rt):       self._r(0, rs, rt, 0, 0, 0x1A)
    def divu(self, rs, rt):      self._r(0, rs, rt, 0, 0, 0x1B)
    def mfhi(self, rd):          self._r(0, 0, 0, rd, 0, 0x10)
    def mthi(self, rs):          self._r(0, rs, 0, 0, 0, 0x11)
    def mflo(self, rd):          self._r(0, 0, 0, rd, 0, 0x12)
    def mtlo(self, rs):          self._r(0, rs, 0, 0, 0, 0x13)

    # --- arithmetic, immediate --------------------------------------------------------
    def addi(self, rt, rs, imm):  self._i(0x08, rs, rt, imm)
    def addiu(self, rt, rs, imm): self._i(0x09, rs, rt, imm)
    def slti(self, rt, rs, imm):  self._i(0x0A, rs, rt, imm)
    def sltiu(self, rt, rs, imm): self._i(0x0B, rs, rt, imm)
    def andi(self, rt, rs, imm):  self._i(0x0C, rs, rt, imm)
    def ori(self, rt, rs, imm):   self._i(0x0D, rs, rt, imm)
    def xori(self, rt, rs, imm):  self._i(0x0E, rs, rt, imm)
    def lui(self, rt, imm):       self._i(0x0F, 0, rt, imm)

    def li(self, rt, value):
        """Load any 32-bit constant: one instruction where it fits, two where not."""
        value &= 0xFFFFFFFF
        if value < 0x10000:
            self.ori(rt, ZERO, value)
        elif value & 0xFFFF == 0:
            self.lui(rt, value >> 16)
        elif value >= 0xFFFF8000:
            self.addiu(rt, ZERO, value & 0xFFFF)
        else:
            self.lui(rt, value >> 16)
            self.ori(rt, rt, value & 0xFFFF)

    def la(self, rt, name):
        """Address of a label, resolved later, always two instructions."""
        self.fixups.append((len(self.code), name, 'hi'))
        self.lui(rt, 0)
        self.fixups.append((len(self.code), name, 'lo'))
        self.addiu(rt, rt, 0)

    # --- memory ---------------------------------------------------------------------------
    def lb(self, rt, off, base):  self._i(0x20, base, rt, off)
    def lh(self, rt, off, base):  self._i(0x21, base, rt, off)
    def lwl(self, rt, off, base): self._i(0x22, base, rt, off)
    def lw(self, rt, off, base):  self._i(0x23, base, rt, off)
    def lbu(self, rt, off, base): self._i(0x24, base, rt, off)
    def lhu(self, rt, off, base): self._i(0x25, base, rt, off)
    def lwr(self, rt, off, base): self._i(0x26, base, rt, off)
    def sb(self, rt, off, base):  self._i(0x28, base, rt, off)
    def sh(self, rt, off, base):  self._i(0x29, base, rt, off)
    def swl(self, rt, off, base): self._i(0x2A, base, rt, off)
    def sw(self, rt, off, base):  self._i(0x2B, base, rt, off)
    def swr(self, rt, off, base): self._i(0x2E, base, rt, off)

    # --- control -------------------------------------------------------------------------------
    def _branch(self, op, rs, rt, name):
        self.fixups.append((len(self.code), name, 'branch'))
        self._i(op, rs, rt, 0)

    def beq(self, rs, rt, name):  self._branch(0x04, rs, rt, name)
    def bne(self, rs, rt, name):  self._branch(0x05, rs, rt, name)
    def blez(self, rs, name):     self._branch(0x06, rs, 0, name)
    def bgtz(self, rs, name):     self._branch(0x07, rs, 0, name)
    def bltz(self, rs, name):     self._branch(0x01, rs, 0x00, name)
    def bgez(self, rs, name):     self._branch(0x01, rs, 0x01, name)
    def bltzal(self, rs, name):   self._branch(0x01, rs, 0x10, name)
    def bgezal(self, rs, name):   self._branch(0x01, rs, 0x11, name)

    def j(self, name):
        self.fixups.append((len(self.code), name, 'jump'))
        self._j(0x02, 0)

    def jal(self, name):
        self.fixups.append((len(self.code), name, 'jump'))
        self._j(0x03, 0)

    def jr(self, rs):            self._r(0, rs, 0, 0, 0, 0x08)
    def jalr(self, rs, rd=RA):   self._r(0, rs, 0, rd, 0, 0x09)
    def syscall(self, code=0):   self._emit((code << 6) | 0x0C)
    def break_(self, code=0):    self._emit((code << 6) | 0x0D)

    # --- COP0 ----------------------------------------------------------------------------------------
    def mfc0(self, rt, rd):      self._emit((0x10 << 26) | (0x00 << 21) | (rt << 16) | (rd << 11))
    def mtc0(self, rt, rd):      self._emit((0x10 << 26) | (0x04 << 21) | (rt << 16) | (rd << 11))
    def rfe(self):               self._emit((0x10 << 26) | (1 << 25) | 0x10)

    # --- COP2: the GTE --------------------------------------------------------------------------------
    # Data registers 0-31 through MFC2/MTC2, control registers through CFC2/CTC2,
    # and the operations themselves as a 25-bit command word after the COP2
    # opcode. LWC2/SWC2 move data registers straight to and from memory.
    def mfc2(self, rt, rd):      self._emit((0x12 << 26) | (0x00 << 21) | (rt << 16) | (rd << 11))
    def cfc2(self, rt, rd):      self._emit((0x12 << 26) | (0x02 << 21) | (rt << 16) | (rd << 11))
    def mtc2(self, rt, rd):      self._emit((0x12 << 26) | (0x04 << 21) | (rt << 16) | (rd << 11))
    def ctc2(self, rt, rd):      self._emit((0x12 << 26) | (0x06 << 21) | (rt << 16) | (rd << 11))
    def lwc2(self, rt, off, base): self._i(0x32, base, rt, off)
    def swc2(self, rt, off, base): self._i(0x3A, base, rt, off)
    def cop2(self, cmd):         self._emit((0x12 << 26) | (1 << 25) | (cmd & 0x01FFFFFF))


def write_hex(words, path):
    """One 32-bit word per line, for $readmemh into a word-wide memory."""
    with open(path, 'w') as f:
        for w in words:
            f.write('%08x\n' % w)
