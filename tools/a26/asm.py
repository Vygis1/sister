#!/usr/bin/env python3
"""A small 6502 assembler for the Atari 2600 test kernels.

Only what the kernels in tools/a26/kernels need: the documented load/store,
arithmetic, logic, shift, branch, jump, stack and flag instructions, labels,
equates, .org/.byte/.word and simple expressions. Writing it beat depending on
an assembler that is not on this machine.

    python tools/a26/asm.py kernel.asm out.bin [-l listing.txt]

The output is the ROM image from the lowest .org to the end of the last byte
emitted, padded to 2K/4K; the reset vector is whatever the source puts at $FFFC.

Syntax: one statement a line, `;` comments, labels end in `:` or start in column
0, `NAME = expr` equates, `.org`, `.byte`, `.word`, `.ds n`. Numbers are
decimal, `$hex`, `%binary`; `<expr` / `>expr` take the low / high byte; `*` is
the current address. Operand forms: `#imm`, `addr`, `addr,x`, `addr,y`,
`(addr),y`, `(addr,x)`, `(addr)` for JMP, and none for implied/accumulator.
"""
import re
import sys

# opcode tables: mnemonic -> {mode: opcode}
# modes: imp acc imm zp zpx zpy abs abx aby izx izy ind rel
OPS = {}


def _add(mn, **modes):
    OPS[mn] = modes


_add('lda', imm=0xA9, zp=0xA5, zpx=0xB5, abs=0xAD, abx=0xBD, aby=0xB9, izx=0xA1, izy=0xB1)
_add('ldx', imm=0xA2, zp=0xA6, zpy=0xB6, abs=0xAE, aby=0xBE)
_add('ldy', imm=0xA0, zp=0xA4, zpx=0xB4, abs=0xAC, abx=0xBC)
_add('sta', zp=0x85, zpx=0x95, abs=0x8D, abx=0x9D, aby=0x99, izx=0x81, izy=0x91)
_add('stx', zp=0x86, zpy=0x96, abs=0x8E)
_add('sty', zp=0x84, zpx=0x94, abs=0x8C)
_add('adc', imm=0x69, zp=0x65, zpx=0x75, abs=0x6D, abx=0x7D, aby=0x79, izx=0x61, izy=0x71)
_add('sbc', imm=0xE9, zp=0xE5, zpx=0xF5, abs=0xED, abx=0xFD, aby=0xF9, izx=0xE1, izy=0xF1)
_add('and', imm=0x29, zp=0x25, zpx=0x35, abs=0x2D, abx=0x3D, aby=0x39, izx=0x21, izy=0x31)
_add('ora', imm=0x09, zp=0x05, zpx=0x15, abs=0x0D, abx=0x1D, aby=0x19, izx=0x01, izy=0x11)
_add('eor', imm=0x49, zp=0x45, zpx=0x55, abs=0x4D, abx=0x5D, aby=0x59, izx=0x41, izy=0x51)
_add('cmp', imm=0xC9, zp=0xC5, zpx=0xD5, abs=0xCD, abx=0xDD, aby=0xD9, izx=0xC1, izy=0xD1)
_add('cpx', imm=0xE0, zp=0xE4, abs=0xEC)
_add('cpy', imm=0xC0, zp=0xC4, abs=0xCC)
_add('bit', zp=0x24, abs=0x2C)
_add('inc', zp=0xE6, zpx=0xF6, abs=0xEE, abx=0xFE)
_add('dec', zp=0xC6, zpx=0xD6, abs=0xCE, abx=0xDE)
_add('asl', acc=0x0A, zp=0x06, zpx=0x16, abs=0x0E, abx=0x1E)
_add('lsr', acc=0x4A, zp=0x46, zpx=0x56, abs=0x4E, abx=0x5E)
_add('rol', acc=0x2A, zp=0x26, zpx=0x36, abs=0x2E, abx=0x3E)
_add('ror', acc=0x6A, zp=0x66, zpx=0x76, abs=0x6E, abx=0x7E)
_add('jmp', abs=0x4C, ind=0x6C)
_add('jsr', abs=0x20)
for mn, op in dict(rts=0x60, rti=0x40, brk=0x00, nop=0xEA, inx=0xE8, iny=0xC8, dex=0xCA, dey=0x88,
                   tax=0xAA, tay=0xA8, txa=0x8A, tya=0x98, tsx=0xBA, txs=0x9A, pha=0x48, php=0x08,
                   pla=0x68, plp=0x28, clc=0x18, sec=0x38, cli=0x58, sei=0x78, clv=0xB8, cld=0xD8,
                   sed=0xF8).items():
    _add(mn, imp=op)
for mn, op in dict(bpl=0x10, bmi=0x30, bvc=0x50, bvs=0x70, bcc=0x90, bcs=0xB0, bne=0xD0, beq=0xF0).items():
    _add(mn, rel=op)

SIZE = dict(imp=1, acc=1, imm=2, zp=2, zpx=2, zpy=2, abs=3, abx=3, aby=3, izx=2, izy=2, ind=3, rel=2)


class Asm:
    def __init__(self):
        self.force_abs = False
        self.syms = {}
        self.out = {}          # address -> byte
        self.pc = 0
        self.pass_ = 1
        self.sizes = {}        # line number -> operand size chosen in pass 1
        self.listing = []

    # --- expressions -------------------------------------------------------
    def number(self, tok):
        tok = tok.strip()
        if tok.startswith('$'):
            return int(tok[1:], 16)
        if tok.startswith('%'):
            return int(tok[1:], 2)
        if tok.startswith("'") and len(tok) == 3:
            return ord(tok[1])
        if re.fullmatch(r'\d+', tok):
            return int(tok)
        if tok == '*':
            return self.pc
        if tok in self.syms:
            return self.syms[tok]
        if self.pass_ == 1:
            self.unresolved = True
            return 0
        raise ValueError('undefined symbol %r' % tok)

    def expr(self, text):
        text = text.strip()
        if text.startswith('<'):
            return self.expr(text[1:]) & 0xFF
        if text.startswith('>'):
            return (self.expr(text[1:]) >> 8) & 0xFF
        # left to right, + and - only, parentheses not supported
        parts = re.split(r'([+\-])', text)
        val = self.number(parts[0])
        for i in range(1, len(parts), 2):
            rhs = self.number(parts[i + 1])
            val = val + rhs if parts[i] == '+' else val - rhs
        return val & 0xFFFF

    # --- emitting ---------------------------------------------------------
    def emit(self, *bs):
        for b in bs:
            if self.pass_ == 2:
                if self.pc in self.out:
                    raise ValueError('overlap at $%04X' % self.pc)
                self.out[self.pc] = b & 0xFF
            self.pc = (self.pc + 1) & 0xFFFF

    # --- one line ---------------------------------------------------------
    def line(self, ln, text):
        self.unresolved = False
        src = text
        text = text.split(';', 1)[0].rstrip()
        if not text.strip():
            return
        start_pc = self.pc
        # equate
        m = re.match(r'^\s*([A-Za-z_]\w*)\s*=\s*(.+)$', text)
        if m:
            self.syms[m.group(1)] = self.expr(m.group(2))
            return
        # label
        m = re.match(r'^([A-Za-z_]\w*):?(\s+.*)?$', text)
        if m and not text[0].isspace():
            name = m.group(1)
            if name.lower() not in OPS and not name.startswith('.'):
                if self.pass_ == 1 and name in self.syms and self.syms[name] != self.pc:
                    raise ValueError('duplicate label %r' % name)
                self.syms[name] = self.pc
                text = m.group(2) or ''
        text = text.strip()
        if not text:
            return
        parts = text.split(None, 1)
        mn = parts[0].lower()
        arg = parts[1].strip() if len(parts) > 1 else ''
        # `sta.w` / `sta.wx` force the absolute form: a 2600 kernel sometimes wants
        # the extra cycle (the classic positioning loop needs it)
        self.force_abs = False
        if '.' in mn and not mn.startswith('.'):
            mn, suffix = mn.split('.', 1)
            self.force_abs = suffix in ('w', 'wx', 'wy')

        if mn == '.org':
            self.pc = self.expr(arg)
        elif mn == '.byte':
            for a in self.split_args(arg):
                self.emit(self.expr(a))
        elif mn == '.word':
            for a in self.split_args(arg):
                v = self.expr(a)
                self.emit(v & 0xFF, v >> 8)
        elif mn == '.ds':
            self.pc = (self.pc + self.expr(arg)) & 0xFFFF
        elif mn in OPS:
            self.instr(ln, mn, arg)
        else:
            raise ValueError('unknown mnemonic %r' % mn)
        if self.pass_ == 2:
            bs = [self.out[a] for a in range(start_pc, self.pc) if a in self.out]
            self.listing.append('%04X  %-12s %s' % (start_pc, ' '.join('%02X' % b for b in bs), src.rstrip()))

    def split_args(self, arg):
        return [a for a in re.split(r',(?=(?:[^\']*\'[^\']*\')*[^\']*$)', arg) if a.strip()]

    def instr(self, ln, mn, arg):
        modes = OPS[mn]
        a = arg.replace(' ', '')
        if a == '' or (a.lower() == 'a' and 'acc' in modes):
            mode = 'acc' if 'acc' in modes else 'imp'
            self.emit(modes[mode])
            return
        if 'rel' in modes:
            target = self.expr(a)
            off = (target - (self.pc + 2)) & 0xFFFF
            if self.pass_ == 2 and not (off < 0x80 or off >= 0xFF80):
                raise ValueError('branch out of range on line %d' % ln)
            self.emit(modes['rel'], off & 0xFF)
            return
        if a.startswith('#'):
            self.emit(modes['imm'], self.expr(a[1:]))
            return
        if a.startswith('('):
            if a.lower().endswith('),y'):
                self.emit(modes['izy'], self.expr(a[1:-3]))
            elif a.lower().endswith(',x)'):
                self.emit(modes['izx'], self.expr(a[1:-3]))
            else:
                v = self.expr(a[1:-1])
                self.emit(modes['ind'], v & 0xFF, v >> 8)
            return
        idx = ''
        if a.lower().endswith(',x'):
            idx, a = 'x', a[:-2]
        elif a.lower().endswith(',y'):
            idx, a = 'y', a[:-2]
        v = self.expr(a)
        zmode = {'': 'zp', 'x': 'zpx', 'y': 'zpy'}[idx]
        amode = {'': 'abs', 'x': 'abx', 'y': 'aby'}[idx]
        # Zero page when the value fits and the instruction has the form, and the
        # choice is frozen in pass 1 so a forward reference cannot change a
        # size between passes and shift every label after it.
        if self.pass_ == 1:
            use_zp = (not self.unresolved) and v < 0x100 and zmode in modes and not self.force_abs
            self.sizes[ln] = 2 if use_zp else 3
        use_zp = self.sizes.get(ln) == 2
        if use_zp:
            self.emit(modes[zmode], v)
        else:
            if amode not in modes:
                raise ValueError('no absolute form for %s on line %d' % (mn, ln))
            self.emit(modes[amode], v & 0xFF, v >> 8)

    # --- driver -----------------------------------------------------------
    def assemble(self, text):
        lines = text.split('\n')
        for p in (1, 2):
            self.pass_ = p
            self.pc = 0
            for ln, l in enumerate(lines, 1):
                try:
                    self.line(ln, l)
                except ValueError as e:
                    raise SystemExit('%s: line %d: %s' % (e, ln, l.strip()))
        return self.out


def main():
    args = sys.argv[1:]
    listing = None
    if '-l' in args:
        i = args.index('-l')
        listing = args[i + 1]
        del args[i:i + 2]
    src, dst = args
    a = Asm()
    out = a.assemble(open(src).read())
    lo, hi = min(out), max(out)
    size = 2048
    while size < hi - lo + 1:
        size *= 2
    base = hi + 1 - size if (hi + 1) % size == 0 else lo
    img = bytearray(size)
    for addr, b in out.items():
        img[addr - base] = b
    open(dst, 'wb').write(img)
    if listing:
        open(listing, 'w').write('\n'.join(a.listing) + '\n')
    print('%s: %d bytes at $%04X-$%04X, image %d bytes' % (dst, hi - lo + 1, lo, hi, size))


if __name__ == '__main__':
    main()
