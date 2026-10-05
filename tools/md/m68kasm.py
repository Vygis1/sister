"""A small 68000 assembler, as a Python module.

Not a parser -- there is no text to parse. Programs are written as Python calls:

    a = Asm(0x400)
    a.moveq(1, D(0))
    a.add_l(D(0), D(1))
    a.label('loop')
    a.dbra(D(2), 'loop')

which is the same shape `tools/sms/smstest.py` and `tools/nes/uxtest.py` already use for
the Z80 and the NES, and for the same reason: the test program IS the test, so
the thing that writes it wants to be in the same language as the thing that
checks it.

Two passes, so a label can be used before it is defined. Every instruction is a
fixed size regardless of what its operands turn out to be -- branches are always
emitted in their 16-bit form -- which is what makes two passes enough and three
unnecessary.

Operands are built by the helpers below:

    D(3)                  D3
    A(3)                  A3
    Ind(3)                (A3)
    Post(3) / Pre(3)      (A3)+ and -(A3)
    Disp(3, -8)           -8(A3)
    Idx(3, D(2), 4)       4(A3,D2.W)
    AbsW(0x3000)          ($3000).W
    AbsL(0x00123456)      ($00123456).L
    PCDisp('table')       table(PC)
    PCIdx(D(2), 'table')  table(PC,D2.W)
    Imm(5)                #5

Sizes are a suffix on the method name: _b, _w, _l. Where an instruction has only
one size there is no suffix.
"""

B, W, L = 0, 1, 2                       # the size field, as the opcodes carry it


# --- operands -----------------------------------------------------------------
# Each is (mode, register, extension) where extension is either a list of words
# or, for an immediate, the raw value -- which cannot be turned into words until
# the instruction says how wide it is.

def D(n):    return (0, n, [])
def A(n):    return (1, n, [])
def Ind(n):  return (2, n, [])
def Post(n): return (3, n, [])
def Pre(n):  return (4, n, [])


def Disp(n, d):
    return (5, n, [d & 0xFFFF])


def _brief(ix, d, long=False):
    """The one extension word shared by both indexed modes."""
    mode, reg, _ = ix
    assert mode in (0, 1), "an index register is a D or an A"
    assert -128 <= d <= 127, "an indexed displacement is one signed byte"
    return ((mode & 1) << 15) | (reg << 12) | (int(long) << 11) | (d & 0xFF)


def Idx(n, ix, d, long=False):
    return (6, n, [_brief(ix, d, long)])


def AbsW(addr):  return (7, 0, [addr & 0xFFFF])


def AbsL(addr):
    # A label is allowed here, and is the way to reach something further off than
    # a branch displacement goes.
    if isinstance(addr, str):
        return (7, 1, [('abs32', addr)])
    return (7, 1, [(addr >> 16) & 0xFFFF, addr & 0xFFFF])


# The two PC-relative modes take a LABEL, not a number: the displacement is from
# the extension word, which the assembler knows and the caller should not have to.
def PCDisp(label):          return (7, 2, [('pcrel16', label)])
def PCIdx(ix, label, long=False): return (7, 3, [('pcrel8', label, ix, long)])


def Imm(v):
    return (7, 4, ('imm', v))


def _is_reg(op):
    return op[0] in (0, 1)


class Asm:
    def __init__(self, org=0):
        self.org = org
        self.labels = {}
        self.final = False
        self.buf = bytearray()

    # --- the two passes ---------------------------------------------------------
    def assemble(self, build):
        """Run `build(self)` twice and return the bytes."""
        self.final = False
        self.buf = bytearray()
        build(self)
        self.final = True
        self.buf = bytearray()
        build(self)
        return bytes(self.buf)

    @property
    def pc(self):
        return self.org + len(self.buf)

    def label(self, name):
        if self.final:
            assert self.labels[name] == self.pc, \
                "label %s moved between passes -- an instruction changed size" % name
        self.labels[name] = self.pc

    def at(self, name):
        if name in self.labels:
            return self.labels[name]
        assert not self.final, "undefined label %s" % name
        return self.org                 # a placeholder of the right size

    # --- raw output --------------------------------------------------------------
    def word(self, w):
        self.buf.append((w >> 8) & 0xFF)
        self.buf.append(w & 0xFF)

    def long(self, v):
        self.word((v >> 16) & 0xFFFF)
        self.word(v & 0xFFFF)

    def byte(self, v):
        self.buf.append(v & 0xFF)

    def align(self, n=2):
        while len(self.buf) % n:
            self.buf.append(0)

    def pad_to(self, addr, fill=0x4E71):
        """Fill forward to an absolute address. The filler is NOP, so running
        into padding by accident walks harmlessly to whatever is next."""
        assert self.pc <= addr, "already past $%06X" % addr
        while self.pc < addr - 1:
            self.word(fill)
        if self.pc < addr:
            self.byte(0)

    # --- effective addresses ------------------------------------------------------
    def _ext(self, op, size):
        """The extension words an operand needs, once the size is known."""
        mode, reg, ext = op
        if isinstance(ext, tuple) and ext and ext[0] == 'imm':
            v = ext[1]
            if isinstance(v, str):
                v = self.at(v)
            if size == L:
                return [(v >> 16) & 0xFFFF, v & 0xFFFF]
            # A byte immediate still occupies a whole word, value in the low half.
            return [v & 0xFFFF]
        out = []
        for e in ext:
            if isinstance(e, tuple) and e[0] == 'pcrel16':
                # Measured from the extension word itself, which is where the
                # program counter is sitting when the CPU reads it.
                here = self.pc + len(out) * 2
                out.append((self.at(e[1]) - here) & 0xFFFF)
            elif isinstance(e, tuple) and e[0] == 'abs32':
                v = self.at(e[1])
                out.append((v >> 16) & 0xFFFF)
                out.append(v & 0xFFFF)
            elif isinstance(e, tuple) and e[0] == 'pcrel8':
                here = self.pc + len(out) * 2
                _, lab, ix, lng = e
                d = self.at(lab) - here
                # The index register is added at run time, so it cannot be
                # accounted for here -- these are for tables reached by a
                # displacement the assembler knows and an index it does not.
                assert -128 <= d <= 127, "PC-relative index displacement too far"
                out.append(_brief(ix, d, lng))
            else:
                out.append(e)
        return out

    def _emit(self, opcode, *ops_and_size):
        """One opcode word followed by every operand's extension words, in the
        order the processor will read them: source first, then destination."""
        size = ops_and_size[-1]
        ops = ops_and_size[:-1]
        self.word(opcode)
        for op in ops:
            for w in self._ext(op, size):
                self.word(w)

    # --- moves ---------------------------------------------------------------------
    def _move(self, size, src, dst):
        sz = {B: 1, W: 3, L: 2}[size]   # MOVE's size field is its own encoding
        op = (sz << 12) | (dst[1] << 9) | (dst[0] << 6) | (src[0] << 3) | src[1]
        self.word(op)
        for w in self._ext(src, size):
            self.word(w)
        for w in self._ext(dst, size):
            self.word(w)

    def move_b(self, s, d): self._move(B, s, d)
    def move_w(self, s, d): self._move(W, s, d)
    def move_l(self, s, d): self._move(L, s, d)

    # MOVEA has its own mnemonic but the same encoding, with an An destination.
    movea_w = move_w
    movea_l = move_l

    def moveq(self, v, dn):
        assert -128 <= v <= 127
        self.word(0x7000 | (dn[1] << 9) | (v & 0xFF))

    # --- the ALU group ---------------------------------------------------------------
    _ALU = {'or': 0x8, 'sub': 0x9, 'cmp': 0xB, 'and': 0xC, 'add': 0xD}

    def _alu(self, name, size, src, dst):
        top = self._ALU[name]
        if dst[0] == 0:
            # <ea> op Dn -> Dn
            self._emit((top << 12) | (dst[1] << 9) | (size << 6)
                       | (src[0] << 3) | src[1], src, size)
        else:
            # Dn op <ea> -> <ea>
            assert src[0] == 0, "the other direction needs a data register source"
            self._emit((top << 12) | (src[1] << 9) | (1 << 8) | (size << 6)
                       | (dst[0] << 3) | dst[1], dst, size)

    def _alua(self, name, size, src, an):
        top = self._ALU[name]
        opmode = 3 if size == W else 7
        self._emit((top << 12) | (an[1] << 9) | (opmode << 6)
                   | (src[0] << 3) | src[1], src, size)

    def eor_b(self, s, d): self._eor(B, s, d)
    def eor_w(self, s, d): self._eor(W, s, d)
    def eor_l(self, s, d): self._eor(L, s, d)

    def _eor(self, size, dn, dst):
        assert dn[0] == 0, "EOR's source is always a data register"
        self._emit(0xB000 | (dn[1] << 9) | (1 << 8) | (size << 6)
                   | (dst[0] << 3) | dst[1], dst, size)

    # --- the immediate forms ------------------------------------------------------------
    _IMM = {'or': 0, 'and': 1, 'sub': 2, 'add': 3, 'eor': 5, 'cmp': 6}

    def _immop(self, name, size, v, dst):
        self.word(0x0000 | (self._IMM[name] << 9) | (size << 6)
                  | (dst[0] << 3) | dst[1])
        for w in self._ext(Imm(v), size):
            self.word(w)
        for w in self._ext(dst, size):
            self.word(w)

    def _quick(self, sub, size, v, dst):
        assert 1 <= v <= 8, "a quick operand is 1 to 8; 8 is encoded as 0"
        self.word(0x5000 | ((v & 7) << 9) | (int(sub) << 8) | (size << 6)
                  | (dst[0] << 3) | dst[1])
        for w in self._ext(dst, size):
            self.word(w)

    # --- the single-operand instructions ---------------------------------------------
    def _unary(self, top, size, dst):
        self._emit(0x4000 | (top << 8) | (size << 6)
                   | (dst[0] << 3) | dst[1], dst, size)

    def tas(self, dst):
        self._emit(0x4AC0 | (dst[0] << 3) | dst[1], dst, B)

    # --- addresses ---------------------------------------------------------------------
    def lea(self, src, an):
        self._emit(0x41C0 | (an[1] << 9) | (src[0] << 3) | src[1], src, L)

    def pea(self, src):
        self._emit(0x4840 | (src[0] << 3) | src[1], src, L)

    # --- bits ---------------------------------------------------------------------------
    _BIT = {'btst': 0, 'bchg': 1, 'bclr': 2, 'bset': 3}

    def _bit(self, name, num, dst):
        t = self._BIT[name]
        if isinstance(num, tuple):                  # the number is in a register
            self._emit(0x0100 | (num[1] << 9) | (t << 6)
                       | (dst[0] << 3) | dst[1], dst, B)
        else:
            self.word(0x0800 | (t << 6) | (dst[0] << 3) | dst[1])
            self.word(num & 0xFFFF)
            for w in self._ext(dst, B):
                self.word(w)

    # --- shifts --------------------------------------------------------------------------
    _SH = {'as': 0, 'ls': 1, 'rox': 2, 'ro': 3}

    def _shift(self, kind, left, size, count, dn):
        t = self._SH[kind]
        if isinstance(count, tuple):                # the count is in a register
            self.word(0xE000 | (count[1] << 9) | (int(left) << 8) | (size << 6)
                      | (1 << 5) | (t << 3) | dn[1])
        else:
            assert 1 <= count <= 8, "an immediate shift count is 1 to 8"
            self.word(0xE000 | ((count & 7) << 9) | (int(left) << 8) | (size << 6)
                      | (t << 3) | dn[1])

    # --- multiply and divide ----------------------------------------------------------------
    def mulu(self, src, dn): self._emit(0xC0C0 | (dn[1] << 9) | (src[0] << 3) | src[1], src, W)
    def muls(self, src, dn): self._emit(0xC1C0 | (dn[1] << 9) | (src[0] << 3) | src[1], src, W)
    def divu(self, src, dn): self._emit(0x80C0 | (dn[1] << 9) | (src[0] << 3) | src[1], src, W)
    def divs(self, src, dn): self._emit(0x81C0 | (dn[1] << 9) | (src[0] << 3) | src[1], src, W)

    # --- the extended forms -------------------------------------------------------------------
    def _x(self, top, size, src, dst):
        # Either both operands are data registers or both are -(An); there is no
        # mixing, because the one bit that says which is shared by the pair.
        mem = src[0] == 4
        assert (dst[0] == 4) == mem, "ADDX and SUBX take two registers or two -(An)"
        self.word((top << 12) | (dst[1] << 9) | (1 << 8) | (size << 6)
                  | (int(mem) << 3) | src[1])

    def addx_l(self, s, d): self._x(0xD, L, s, d)
    def subx_l(self, s, d): self._x(0x9, L, s, d)

    def cmpm_l(self, src, dst):
        assert src[0] == 3 and dst[0] == 3, "CMPM walks two (An)+ pointers"
        self.word(0xB188 | (dst[1] << 9) | src[1])

    def negx_l(self, dst): self._unary(0x00, L, dst)

    # --- registers ------------------------------------------------------------------------------
    def swap(self, dn):   self.word(0x4840 | dn[1])
    def ext_w(self, dn):  self.word(0x4880 | dn[1])
    def ext_l(self, dn):  self.word(0x48C0 | dn[1])

    def exg(self, x, y):
        if x[0] == 0 and y[0] == 0:   mode = 0x08
        elif x[0] == 1 and y[0] == 1: mode = 0x09
        elif x[0] == 0 and y[0] == 1: mode = 0x11
        else: raise AssertionError("EXG An,Dn is written EXG Dn,An")
        self.word(0xC100 | (x[1] << 9) | (mode << 3) | y[1])

    # --- control flow ------------------------------------------------------------------------------
    _CC = ['t', 'f', 'hi', 'ls', 'cc', 'cs', 'ne', 'eq',
           'vc', 'vs', 'pl', 'mi', 'ge', 'lt', 'gt', 'le']

    def _disp16(self, label):
        """A branch displacement, checked. Sixteen signed bits reaches 32 kB in
        either direction and no further -- and past that the displacement does
        not fail, it silently comes out NEGATIVE and the program lands somewhere
        near minus one. Anything further away wants JMP or JSR."""
        d = self.at(label) - self.pc
        assert -32768 <= d <= 32767, \
            "%s is %d bytes away, too far for a 16-bit branch" % (label, d)
        return d & 0xFFFF

    def branch(self, cc, label):
        """Always the 16-bit form, so the instruction is four bytes whatever the
        distance turns out to be and two passes are enough."""
        self.word(0x6000 | (self._CC.index(cc) << 8))
        self.word(self._disp16(label))

    def bra(self, label): self.branch('t', label)
    def bsr(self, label): self.branch('f', label)

    def dbranch(self, cc, dn, label):
        self.word(0x50C8 | (self._CC.index(cc) << 8) | dn[1])
        self.word(self._disp16(label))

    def dbra(self, dn, label): self.dbranch('f', dn, label)

    def setcc(self, cc, dst):
        self._emit(0x50C0 | (self._CC.index(cc) << 8)
                   | (dst[0] << 3) | dst[1], dst, B)

    def jmp(self, dst): self._emit(0x4EC0 | (dst[0] << 3) | dst[1], dst, L)
    def jsr(self, dst): self._emit(0x4E80 | (dst[0] << 3) | dst[1], dst, L)

    def rts(self):     self.word(0x4E75)
    def rte(self):     self.word(0x4E73)
    def nop(self):     self.word(0x4E71)
    def illegal(self): self.word(0x4AFC)
    def trap(self, n): self.word(0x4E40 | (n & 15))
    def stop(self, sr): self.word(0x4E72); self.word(sr & 0xFFFF)

    def link(self, an, d):
        self.word(0x4E50 | an[1])
        self.word(d & 0xFFFF)

    def unlk(self, an): self.word(0x4E58 | an[1])

    # --- the status register ---------------------------------------------------------------------
    def move_to_sr(self, src):  self._emit(0x46C0 | (src[0] << 3) | src[1], src, W)
    def move_from_sr(self, dst): self._emit(0x40C0 | (dst[0] << 3) | dst[1], dst, W)
    def move_to_ccr(self, src): self._emit(0x44C0 | (src[0] << 3) | src[1], src, W)

    def andi_to_sr(self, v):  self.word(0x027C); self.word(v & 0xFFFF)
    def ori_to_sr(self, v):   self.word(0x007C); self.word(v & 0xFFFF)
    def eori_to_sr(self, v):  self.word(0x0A7C); self.word(v & 0xFFFF)
    def andi_to_ccr(self, v): self.word(0x023C); self.word(v & 0xFFFF)
    def ori_to_ccr(self, v):  self.word(0x003C); self.word(v & 0xFFFF)


# The size-suffixed spellings, generated rather than written out sixty times.
def _install():
    for name in ('add', 'sub', 'and', 'or', 'cmp'):
        for suffix, size in (('b', B), ('w', W), ('l', L)):
            def alu(self, s, d, _n=name, _z=size): self._alu(_n, _z, s, d)
            setattr(Asm, '%s_%s' % (name, suffix), alu)

    # EOR is in the immediate group but not in the register group -- it has no
    # <ea>-to-Dn direction, so it gets its own method above rather than one here.
    for name in Asm._IMM:
        for suffix, size in (('b', B), ('w', W), ('l', L)):
            def immop(self, v, d, _n=name, _z=size): self._immop(_n, _z, v, d)
            setattr(Asm, '%si_%s' % (name, suffix), immop)

    for name in ('add', 'sub', 'cmp'):
        for suffix, size in (('w', W), ('l', L)):
            def alua(self, s, a, _n=name, _z=size): self._alua(_n, _z, s, a)
            setattr(Asm, '%sa_%s' % (name, suffix), alua)

    for name, sub in (('addq', False), ('subq', True)):
        for suffix, size in (('b', B), ('w', W), ('l', L)):
            def q(self, v, d, _s=sub, _z=size): self._quick(_s, _z, v, d)
            setattr(Asm, '%s_%s' % (name, suffix), q)

    for name, top in (('negx', 0x00), ('clr', 0x02), ('neg', 0x04),
                      ('not', 0x06), ('tst', 0x0A)):
        for suffix, size in (('b', B), ('w', W), ('l', L)):
            def u(self, d, _t=top, _z=size): self._unary(_t, _z, d)
            setattr(Asm, '%s_%s' % (name, suffix), u)

    for name in ('btst', 'bchg', 'bclr', 'bset'):
        def bit(self, n, d, _n=name): self._bit(_n, n, d)
        setattr(Asm, name, bit)

    for kind in ('as', 'ls', 'rox', 'ro'):
        for lr, left in (('l', True), ('r', False)):
            for suffix, size in (('b', B), ('w', W), ('l', L)):
                def sh(self, c, d, _k=kind, _l=left, _z=size):
                    self._shift(_k, _l, _z, c, d)
                setattr(Asm, '%s%s_%s' % (kind, lr, suffix), sh)

    for cc in Asm._CC[2:]:
        def b(self, label, _c=cc): self.branch(_c, label)
        setattr(Asm, 'b' + cc, b)

        def db(self, dn, label, _c=cc): self.dbranch(_c, dn, label)
        setattr(Asm, 'db' + cc, db)

        def sc(self, dst, _c=cc): self.setcc(_c, dst)
        setattr(Asm, 's' + cc, sc)


_install()


# MOVEM needs the mask word between the opcode and the address's extension
# words, which is the one place the plain "opcode then operands" shape does not
# hold. Rather than complicate _emit for a single instruction, it is written out.
def _movem(self, opcode, mask, op, size):
    self.word(opcode)
    self.word(mask)
    for w in self._ext(op, size):
        self.word(w)


def _mask(regs, predec=False):
    """Turn a list of operands into MOVEM's register mask. Bit 0 is D0 -- except
    for a -(An) destination, where the whole list runs backwards and bit 0 is
    A7. Getting that round the wrong way saves the right registers in the wrong
    order, which a stack frame does not survive."""
    m = 0
    for r in regs:
        n = r[1] + (8 if r[0] == 1 else 0)
        m |= 1 << ((15 - n) if predec else n)
    return m


def _movem_to_mem(self, size, regs, dst):
    _movem(self, 0x4880 | (int(size == L) << 6) | (dst[0] << 3) | dst[1],
           _mask(regs, dst[0] == 4), dst, size)


def _movem_to_reg(self, size, src, regs):
    _movem(self, 0x4C80 | (int(size == L) << 6) | (src[0] << 3) | src[1],
           _mask(regs), src, size)


Asm.movem_to_mem = _movem_to_mem
Asm.movem_to_reg = _movem_to_reg


# --- the assembler's own check -------------------------------------------------
# Run this file directly to verify it:
#
#     python tools/md/m68kasm.py
#
# Every encoding below was worked out by hand against the manual while the CPU's
# tests were being written, and then confirmed by the CPU executing it and
# producing the right answer. So they are not a restatement of what this file
# does -- they are an independent record of what the opcodes are.
KNOWN = [
    (lambda a: a.move_l(Imm(0x12345678), D(0)), "203C12345678"),
    (lambda a: a.move_l(Imm(0x12345678), D(1)), "223C12345678"),
    (lambda a: a.move_l(D(7), Ind(0)),          "2087"),
    (lambda a: a.move_l(Ind(0), D(7)),          "2E10"),
    (lambda a: a.move_b(Ind(0), D(4)),          "1810"),
    (lambda a: a.movea_l(Imm(0x2000), A(0)),    "207C00002000"),
    (lambda a: a.movea_l(Ind(0), A(2)),         "2450"),
    (lambda a: a.moveq(5, D(5)),                "7A05"),
    (lambda a: a.add_l(D(3), D(1)),             "D283"),
    (lambda a: a.add_l(D(6), Ind(0)),           "DD90"),
    (lambda a: a.sub_l(D(7), D(5)),             "9A87"),
    (lambda a: a.sub_l(D(6), Ind(0)),           "9D90"),
    (lambda a: a.or_w(D(3), Ind(0)),            "8750"),
    (lambda a: a.eor_w(D(3), D(2)),             "B742"),
    (lambda a: a.adda_w(Imm(-2), A(2)),         "D4FCFFFE"),
    (lambda a: a.addi_l(0x234, D(0)),           "068000000234"),
    (lambda a: a.subi_w(0x34, D(0)),            "04400034"),
    (lambda a: a.andi_w(0x00F0, D(1)),          "024100F0"),
    (lambda a: a.ori_w(0x0F00, D(1)),           "00410F00"),
    (lambda a: a.eori_w(0xFFFF, D(1)),          "0A41FFFF"),
    (lambda a: a.cmpi_b(0x55, D(2)),            "0C020055"),
    (lambda a: a.addi_l(5, Ind(0)),             "069000000005"),
    (lambda a: a.addi_w(1, Post(1)),            "06590001"),
    (lambda a: a.addq_l(1, D(0)),               "5280"),
    (lambda a: a.addq_w(8, D(0)),               "5040"),
    (lambda a: a.subq_b(3, D(0)),               "5700"),
    (lambda a: a.addq_l(8, A(1)),               "5089"),
    (lambda a: a.subq_w(2, A(1)),               "5549"),
    (lambda a: a.clr_w(D(3)),                   "4243"),
    (lambda a: a.clr_w(Ind(0)),                 "4250"),
    (lambda a: a.neg_w(D(4)),                   "4444"),
    (lambda a: a.not_w(D(6)),                   "4646"),
    (lambda a: a.tst_l(D(5)),                   "4A85"),
    (lambda a: a.tst_b(D(5)),                   "4A05"),
    (lambda a: a.tas(Ind(0)),                   "4AD0"),
    (lambda a: a.lea(AbsL(0x3000), A(0)),       "41F900003000"),
    (lambda a: a.pea(Ind(1)),                   "4851"),
    (lambda a: a.bset(3, D(0)),                 "08C00003"),
    (lambda a: a.bset(9, Ind(0)),               "08D00009"),
    (lambda a: a.bset(D(1), D(2)),              "03C2"),
    (lambda a: a.bclr(3, D(0)),                 "08800003"),
    (lambda a: a.bchg(0, D(0)),                 "08400000"),
    (lambda a: a.btst(31, D(0)),                "0800001F"),
    (lambda a: a.asr_w(1, D(0)),                "E240"),
    (lambda a: a.lsr_w(1, D(1)),                "E249"),
    (lambda a: a.asl_b(1, D(2)),                "E302"),
    (lambda a: a.lsl_b(1, D(3)),                "E30B"),
    (lambda a: a.rol_w(4, D(4)),                "E95C"),
    (lambda a: a.ror_w(4, D(5)),                "E85D"),
    (lambda a: a.lsl_l(D(7), D(6)),             "EFAE"),
    (lambda a: a.roxl_b(1, D(6)),               "E316"),
    (lambda a: a.mulu(D(1), D(0)),              "C0C1"),
    (lambda a: a.muls(D(2), D(3)),              "C7C2"),
    (lambda a: a.mulu(D(2), D(4)),              "C8C2"),
    (lambda a: a.divu(D(6), D(5)),              "8AC6"),
    (lambda a: a.divs(Imm(7), D(7)),            "8FFC0007"),
    (lambda a: a.divu(Imm(1), D(0)),            "80FC0001"),
    (lambda a: a.addx_l(D(2), D(0)),            "D182"),
    (lambda a: a.subx_l(D(6), D(4)),            "9986"),
    (lambda a: a.addx_l(Pre(1), Pre(0)),        "D189"),
    (lambda a: a.cmpm_l(Post(1), Post(0)),      "B189"),
    (lambda a: a.negx_l(D(7)),                  "4087"),
    (lambda a: a.swap(D(1)),                    "4841"),
    (lambda a: a.ext_w(D(0)),                   "4880"),
    (lambda a: a.ext_l(D(0)),                   "48C0"),
    (lambda a: a.exg(A(2), A(3)),               "C54B"),
    (lambda a: a.exg(D(4), A(3)),               "C98B"),
    (lambda a: a.link(A(6), -8),                "4E56FFF8"),
    (lambda a: a.unlk(A(6)),                    "4E5E"),
    (lambda a: a.seq(D(6)),                     "57C6"),
    (lambda a: a.sne(D(7)),                     "56C7"),
    (lambda a: a.trap(0),                       "4E40"),
    (lambda a: a.rts(),                         "4E75"),
    (lambda a: a.rte(),                         "4E73"),
    (lambda a: a.stop(0x2700),                  "4E722700"),
    (lambda a: a.andi_to_sr(0xF8FF),            "027CF8FF"),
    (lambda a: a.move_to_ccr(Imm(0)),           "44FC0000"),
    (lambda a: a.move_l(Disp(0, 4), D(5)),      "2A280004"),
    (lambda a: a.move_l(D(1), Disp(0, 4)),      "21410004"),
    (lambda a: a.move_l(Idx(0, D(2), 0), D(3)), "26302000"),
    (lambda a: a.move_l(Idx(0, D(2), -4), D(6)), "2C3020FC"),
    (lambda a: a.move_l(Post(0), D(6)),         "2C18"),
    (lambda a: a.move_l(D(0), Post(0)),         "20C0"),
    (lambda a: a.movea_l(A(0), A(1)),           "2248"),
    (lambda a: a.movem_to_mem(L, [D(0), D(1), D(2), D(3)], Ind(0)), "48D0000F"),
    (lambda a: a.movem_to_reg(L, Ind(0), [D(0), D(1), D(2), D(3)]), "4CD0000F"),
    (lambda a: a.movem_to_mem(L, [D(0), D(1), A(0)], Pre(1)),       "48E1C080"),
    (lambda a: a.movem_to_reg(L, Post(1), [D(4), D(5), A(2)]),      "4CD90430"),
    (lambda a: a.movem_to_mem(W, [D(6)], Ind(3)),                   "48930040"),
    (lambda a: a.movem_to_reg(W, Ind(3), [D(7)]),                   "4C930080"),
]


def _selfcheck():
    bad = 0
    for fn, want in KNOWN:
        got = Asm(0).assemble(fn).hex().upper()
        if got != want:
            print("  FAIL: wanted %s, got %s" % (want, got))
            bad += 1

    # Labels, both directions, and the form that measures from an extension word
    # rather than from the opcode.
    def prog(a):
        a.label("top")
        a.moveq(0, D(0))
        a.bra("skip")
        a.moveq(1, D(0))
        a.label("skip")
        a.dbra(D(1), "top")
        a.move_l(PCDisp("table"), D(2))
        a.label("table")
        a.long(0xDEADBEEF)
    out = Asm(0x400).assemble(prog)
    # Every displacement here is measured from the EXTENSION WORD, not from the
    # opcode, which is where an off-by-two comes from if it comes from anywhere.
    # MOVEQ(2) BRA(4) MOVEQ(2) DBRA(4) puts the MOVE at $40C, its extension word
    # at $40E and the table at $410, so the displacement is 2 and not 4.
    for where, want, what in ((12, "243A0002", "PC-relative"),
                              (2,  "60000004", "forward branch"),
                              (8,  "51C9FFF6", "backward DBRA")):
        got = out[where:where + 4].hex().upper()
        if got != want:
            print("  FAIL: %s came out %s, wanted %s" % (what, got, want))
            bad += 1

    total = len(KNOWN) + 3
    if bad:
        print("m68kasm: %d FAIL(s) of %d" % (bad, total))
    else:
        print("m68kasm: all %d encodings match" % total)
    return bad


if __name__ == "__main__":
    import sys
    sys.exit(1 if _selfcheck() else 0)
