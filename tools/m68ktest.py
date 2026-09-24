"""Generate a self-checking 68000 test program.

    python tools/m68ktest.py sim/roms/m68k/m68ktest.hex

The interesting part is not the program, it is the model. Every case below is
computed twice: once in Python, by the rules in the manual, and once by the
Verilog, by whatever it actually does. The program compares them and stops at
the first disagreement, recording which case it was and what both sides said.
That is the "reference that disagrees loudly" the other two CPUs in this tree
were built against, and it is the only approach that has worked here.

The sweep is over operand pairs chosen to sit on the boundaries where the flags
change: zero, one, minus one, the largest positive value, the most negative
value, and a couple of middles. Those are where an X that should have been left
alone, or an overflow computed from the wrong pair of signs, actually shows.

Results land at $81000:

    $81000  word   the number of the first case that failed, 0 if none did,
                  and $FFFF if an exception nobody asked for was taken
    $81002  word   how many checks ran
    $81004  long   what the processor produced
    $81008  long   what it should have produced
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m68kasm import *                                        # noqa: E402

# The program is generated, so it is large -- tens of kilobytes rather than the
# few hundred bytes a hand-written one runs to. Everything it needs therefore
# lives well above it, and the testbench gives it a megabyte to sit in.
RESULT = 0x81000
COUNT  = 0x81002
ACTUAL = 0x81004
WANTED = 0x81008

STACK  = 0x80000
START  = 0x000400
LIMIT  = 0x70000                # the program must end well below the stack

MASK   = {B: 0xFF, W: 0xFFFF, L: 0xFFFFFFFF}
BITS   = {B: 8,    W: 16,     L: 32}


# --- the model ----------------------------------------------------------------
def _sign(v, size):
    return (v >> (BITS[size] - 1)) & 1


def alu(op, size, a, b, x_in):
    """`a` is the destination, `b` the source: the instruction computes a op b.
    Returns (result, X, N, Z, V, C) with the result already masked to size."""
    m = MASK[size]
    a &= m
    b &= m
    sa, sb = _sign(a, size), _sign(b, size)
    x, c, v = x_in, 0, 0

    if op == 'add':
        r = a + b
        c = (r >> BITS[size]) & 1
        r &= m
        v = 1 if (sa == sb and _sign(r, size) != sa) else 0
        x = c
    elif op in ('sub', 'cmp'):
        r = (a - b) & m
        c = 1 if b > a else 0
        v = 1 if (sa != sb and _sign(r, size) != sa) else 0
        if op == 'sub':
            x = c
    elif op == 'and':
        r = a & b
    elif op == 'or':
        r = a | b
    elif op == 'eor':
        r = a ^ b
    else:
        raise ValueError(op)

    n = _sign(r, size)
    z = 1 if r == 0 else 0
    # A compare keeps its answer to itself; everything else writes it back.
    return (a if op == 'cmp' else r), x, n, z, v, c


def shift(kind, left, size, n, a, x_in):
    """One of the eight shifts and rotates. `n` may be 0, which is its own case:
    the carry comes out clear and X is not touched at all."""
    w = BITS[size]
    m = MASK[size]
    a &= m
    x, c, v = x_in, 0, 0
    r = a

    if n == 0:
        pass
    elif kind in ('as', 'ls') and left:
        c = (a >> (w - n)) & 1 if n <= w else 0
        r = (a << n) & m
        x = c
        if kind == 'as':
            # The overflow flag means "the sign moved at some point", so it is
            # about the top n+1 bits together, not about the two ends.
            top = a >> (w - n - 1) if n < w else a
            v = 0 if top in (0, (1 << (n + 1)) - 1) else 1
    elif kind == 'as':                                   # ASR
        c = (a >> (n - 1)) & 1 if n <= w else _sign(a, size)
        sh = min(n, w - 1)
        r = ((a >> sh) | (m << (w - sh) if _sign(a, size) else 0)) & m
        if n >= w:
            r = m if _sign(a, size) else 0
        x = c
    elif kind == 'ls':                                   # LSR
        c = (a >> (n - 1)) & 1 if n <= w else 0
        r = (a >> n) & m if n < w else 0
        x = c
    elif kind == 'ro':
        k = n % w
        if left:
            r = ((a << k) | (a >> (w - k))) & m if k else a
            c = r & 1 if n else 0
        else:
            r = ((a >> k) | (a << (w - k))) & m if k else a
            c = _sign(r, size) if n else 0
    else:                                                # ROXL / ROXR
        wide = (x_in << w) | a
        k = n % (w + 1)
        if left:
            wide = ((wide << k) | (wide >> (w + 1 - k))) & ((1 << (w + 1)) - 1) if k else wide
        else:
            wide = ((wide >> k) | (wide << (w + 1 - k))) & ((1 << (w + 1)) - 1) if k else wide
        x = (wide >> w) & 1
        r = wide & m
        c = x

    return r, x, _sign(r, size), 1 if r == 0 else 0, v, c


def muldiv(op, dvd, dvr, x_in):
    """MULU, MULS, DIVU and DIVS. Returns (result, flags, mask) where the mask
    says which flag bits are worth comparing -- after a divide overflows, N and Z
    are undefined, so only X, V and C mean anything."""
    dvd &= 0xFFFFFFFF
    dvr &= 0xFFFF

    if op in ('mulu', 'muls'):
        a = dvd & 0xFFFF
        b = dvr
        if op == 'muls':
            if a >= 0x8000: a -= 0x10000
            if b >= 0x8000: b -= 0x10000
        r = (a * b) & 0xFFFFFFFF
        return r, ccr(x_in, (r >> 31) & 1, 1 if r == 0 else 0, 0, 0), 0x1F

    # A divide by zero is an exception rather than an answer, and has its own
    # test in tb_m68k.
    assert dvr != 0
    a, b = dvd, dvr
    if op == 'divs':
        if a >= 0x80000000: a -= 0x100000000
        if b >= 0x8000:     b -= 0x10000
    # Truncated toward zero, and the remainder keeps the DIVIDEND's sign --
    # which is not what Python's // and % do with negative numbers.
    q = abs(a) // abs(b)
    r = abs(a) % abs(b)
    if op == 'divs':
        if (a < 0) != (b < 0):
            q = -q
        if a < 0:
            r = -r
        over = not (-32768 <= q <= 32767)
    else:
        over = q > 0xFFFF

    if over:
        # Nothing is written, V is set, and the carry is cleared anyway.
        return dvd, ccr(x_in, 0, 0, 1, 0), 0x13

    q &= 0xFFFF
    r &= 0xFFFF
    return (r << 16) | q, ccr(x_in, (q >> 15) & 1, 1 if q == 0 else 0, 0, 0), 0x1F


def ccr(x, n, z, v, c):
    return (x << 4) | (n << 3) | (z << 2) | (v << 1) | c


# --- the operand pairs the sweep walks ------------------------------------------------
# A full cross product of the interesting values is thousands of cases and most of
# them say the same thing twice. These twelve are the corners: every combination
# of signs, both directions of carry and borrow, and the two values where adding
# one changes the sign.
def pairs(size):
    m = MASK[size]
    top = 1 << (BITS[size] - 1)
    return [
        (0, 0),                  # nothing happens, and Z says so
        (0, 1),
        (1, m),                  # 1 + -1: zero with a carry out
        (m, 1),
        (m, m),                  # -1 + -1: the other way round
        (top - 1, 1),            # the largest positive, plus one
        (top, m),                # the most negative, minus one
        (top, 1),
        (top - 1, top - 1),      # two positives that overflow together
        (top, top),              # two negatives that do
        (0x5A & m, 0xA5 & m),
        (0xA5A5A5A5 & m, 0x5A5A5A5A & m),
    ]


# --- the program ---------------------------------------------------------------------
class Gen:
    def __init__(self):
        self.case = 0
        self.cases = []          # (number, description) for the testbench's benefit

    def build(self, a):
        # Two passes, so this runs twice. Without the reset the case numbers in
        # the second pass carry on from the first, and the listing comes out
        # twice as long as the program it describes.
        self.case = 0
        self.cases = []
        a.org = 0
        # The vector table. Only the first two entries matter here; the rest
        # point at a handler that records "an exception happened" rather than
        # running off into whatever the padding decodes as.
        a.long(STACK)
        a.long(START)
        # Every other vector points at the same handler. An exception nobody
        # asked for is a failure, and it should say so rather than vectoring
        # through a zero and quietly restarting the whole program.
        for _ in range(2, 64):
            a.long(a.at('trapped'))
        a.pad_to(START)

        # The checker and the two stopping places go FIRST, and the reset vector
        # skips over them. They are reached from every case in a program tens of
        # kilobytes long, so they are called absolutely rather than branched to.
        a.jmp(AbsL('start'))

        # D0 is what happened, D1 is what should have, D2 is which case. Kept as a
        # subroutine so a case costs four instructions rather than twelve.
        a.label('checker')
        a.addq_w(1, AbsL(COUNT))
        a.cmp_l(D(1), D(0))
        a.beq('checker_ok')
        a.move_w(D(2), AbsL(RESULT))
        a.move_l(D(0), AbsL(ACTUAL))
        a.move_l(D(1), AbsL(WANTED))
        a.bra('done')            # the stack is abandoned; we are stopping anyway
        a.label('checker_ok')
        a.rts()

        a.label('done')
        a.stop(0x2700)
        a.bra('done')

        a.label('trapped')
        a.move_w(Imm(0xFFFF), AbsL(RESULT))
        a.stop(0x2700)
        a.bra('trapped')

        a.label('start')
        a.move_w(Imm(0), AbsL(RESULT))
        a.move_w(Imm(0), AbsL(COUNT))

        self.alu_sweep(a)
        self.shift_sweep(a)
        self.muldiv_sweep(a)

        a.jmp(AbsL('done'))

        assert a.pc < LIMIT, \
            'the program reaches $%06X, which is into the stack at $%06X' % (
                a.pc, STACK)

    # --- multiply and divide ----------------------------------------------------------
    DIVIDENDS = [0, 1, 0xFFFF, 0x10000, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF,
                 0x12345678, 0xFFFFFF9C]
    DIVISORS  = [1, 2, 3, 7, 0x00FF, 0x8000, 0xFFFF]

    def muldiv_sweep(self, a):
        for op in ('mulu', 'muls', 'divu', 'divs'):
            emit = getattr(Asm, op)
            for dvd in self.DIVIDENDS:
                for dvr in self.DIVISORS:
                    self.muldiv_case(a, emit, op, dvd, dvr)

    def muldiv_case(self, a, emit, op, dvd, dvr):
        want_r, want_cc, mask = muldiv(op, dvd, dvr, 1)

        a.moveq(0, D(4))
        a.move_l(Imm(dvd), D(0))
        a.move_l(Imm(dvr), D(3))
        # X goes in SET, so a multiply or divide that wrongly touched it shows up
        # as a cleared bit rather than as nothing at all -- and C goes in set
        # too, because both instructions are supposed to clear it and a rule
        # that says "clear" is not tested by starting from clear.
        a.move_to_ccr(Imm((1 << 4) | 1))
        emit(a, D(3), D(0))
        a.move_from_sr(D(4))
        a.move_l(D(0), D(5))
        a.andi_l(mask, D(4))
        a.move_l(D(4), D(0))
        self.check(a, want_cc & mask,
                   '%s $%X by $%X flags' % (op, dvd, dvr))
        a.move_l(D(5), D(0))
        self.check(a, want_r, '%s $%X by $%X result' % (op, dvd, dvr))

    def check(self, a, want, what):
        """Emit a comparison of D0 against `want`. D0 must already hold the value."""
        self.case += 1
        self.cases.append((self.case, what))
        a.move_l(Imm(want & 0xFFFFFFFF), D(1))
        a.move_w(Imm(self.case), D(2))
        a.jsr(AbsL('checker'))

    # --- the ALU -----------------------------------------------------------------------
    def alu_sweep(self, a):
        for op in ('add', 'sub', 'and', 'or', 'eor', 'cmp'):
            for size, suffix in ((B, 'b'), (W, 'w'), (L, 'l')):
                emit = getattr(Asm, '%s_%s' % (op, suffix))
                for x_in in (0, 1):
                    for va, vb in pairs(size):
                        self.alu_case(a, emit, op, size, suffix, va, vb, x_in)

    def alu_case(self, a, emit, op, size, suffix, va, vb, x_in):
        r, x, n, z, v, c = alu(op, size, va, vb, x_in)
        want_cc = ccr(x, n, z, v, c)
        # The upper part of the destination register must survive a byte or word
        # operation, so it is seeded with something recognisable rather than zero.
        seed = 0x5EED0000 & ~MASK[size]
        want_r = seed | r

        a.moveq(0, D(4))                      # clears the half MOVE SR will not
        a.move_l(Imm(seed | (va & MASK[size])), D(0))
        a.move_l(Imm(vb & MASK[size]), D(3))
        a.move_to_ccr(Imm(x_in << 4))         # X set or clear, nothing else
        emit(a, D(3), D(0))
        a.move_from_sr(D(4))                  # flags first: nothing else may run
        a.move_l(D(0), D(5))                  # then the result, before it moves
        a.andi_l(0x1F, D(4))
        a.move_l(D(4), D(0))
        self.check(a, want_cc,
                   '%s.%s $%X,$%X X=%d flags' % (op, suffix, vb, va, x_in))
        a.move_l(D(5), D(0))
        self.check(a, want_r,
                   '%s.%s $%X,$%X X=%d result' % (op, suffix, vb, va, x_in))

    # --- the shifts ---------------------------------------------------------------------
    def shift_sweep(self, a):
        for kind in ('as', 'ls', 'rox', 'ro'):
            # Only the two rotates through X care what X was coming in. For the
            # others it is an output, so one run with it SET is what proves an
            # arithmetic shift overwrites it and a plain rotate leaves it alone.
            xs = (0, 1) if kind == 'rox' else (1,)
            for lr, left in (('l', True), ('r', False)):
                for size, suffix in ((B, 'b'), (W, 'w'), (L, 'l')):
                    emit = getattr(Asm, '%s%s_%s' % (kind, lr, suffix))
                    for x_in in xs:
                        # 8 is the largest count an opcode can carry, and for a
                        # byte it shifts the whole thing out -- which is where
                        # the carry rule stops being the obvious one.
                        for n in (1, 2, 8):
                            for va in (0x01, MASK[size], 0x5A & MASK[size],
                                       1 << (BITS[size] - 1)):
                                self.shift_case(a, emit, kind, lr, size,
                                                suffix, n, va, x_in)

        # A count held in a register reaches the two places an immediate cannot:
        # zero, which must clear the carry and leave X alone, and anything past
        # the width of the operand.
        for kind in ('as', 'ls', 'rox', 'ro'):
            for lr in ('l', 'r'):
                for size, suffix in ((B, 'b'), (W, 'w'), (L, 'l')):
                    emit = getattr(Asm, '%s%s_%s' % (kind, lr, suffix))
                    for n in (0, 9, 33, 64 + 4):
                        for va in (0x5A & MASK[size], MASK[size]):
                            self.shift_case(a, emit, kind, lr, size, suffix,
                                            n, va, 1, in_reg=True)

    def shift_case(self, a, emit, kind, lr, size, suffix, n, va, x_in,
                   in_reg=False):
        # A register count is taken modulo 64, which is why 68 is a shift of 4
        # and 64 itself is a shift of nothing.
        r, x, nn, z, v, c = shift(kind, lr == 'l', size,
                                  (n % 64) if in_reg else n, va, x_in)
        want_cc = ccr(x, nn, z, v, c)
        seed = 0x5EED0000 & ~MASK[size]
        want_r = seed | r

        a.moveq(0, D(4))
        a.move_l(Imm(seed | (va & MASK[size])), D(0))
        if in_reg:
            a.move_l(Imm(n), D(6))
        a.move_to_ccr(Imm(x_in << 4))
        emit(a, D(6) if in_reg else n, D(0))
        a.move_from_sr(D(4))
        a.move_l(D(0), D(5))
        a.andi_l(0x1F, D(4))
        a.move_l(D(4), D(0))
        how = ('D6=%d' % n) if in_reg else ('#%d' % n)
        self.check(a, want_cc,
                   '%s%s.%s %s of $%X X=%d flags' % (kind, lr, suffix, how, va, x_in))
        a.move_l(D(5), D(0))
        self.check(a, want_r,
                   '%s%s.%s %s of $%X X=%d result' % (kind, lr, suffix, how, va, x_in))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else 'sim/roms/m68k/m68ktest.hex'
    gen = Gen()
    code = Asm(0).assemble(gen.build)

    os.makedirs(os.path.dirname(out) or '.', exist_ok=True)
    with open(out, 'w') as f:
        for i in range(0, len(code), 2):
            f.write('%02x%02x\n' % (code[i], code[i + 1]))

    listing = os.path.splitext(out)[0] + '.txt'
    with open(listing, 'w') as f:
        f.write('# case numbers, for reading a failure back\n')
        for num, what in gen.cases:
            f.write('%d\t%s\n' % (num, what))

    print('%s: %d bytes, %d checks' % (out, len(code), gen.case))
    print('%s: what each case number means' % listing)


if __name__ == '__main__':
    main()
