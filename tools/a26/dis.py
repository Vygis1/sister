#!/usr/bin/env python3
"""Disassemble part of one 4K bank of a 2600 cartridge image (documented opcodes).

    python tools/a26/dis.py game.bin BANK FROM TO        e.g.  game.bin 1 F140 F1D0

Uses the opcode table of tools/a26/asm.py, so it reads what that assembler writes
and the ordinary instructions of any other cartridge; undocumented opcodes show
as .byte. For finding where a kernel is stuck when tb_a26 says it is looping.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asm import OPS, SIZE  # noqa: E402

FMT2 = {'imm': '#$%02X', 'zp': '$%02X', 'zpx': '$%02X,x', 'zpy': '$%02X,y',
        'izx': '($%02X,x)', 'izy': '($%02X),y'}
FMT3 = {'abs': '$%04X', 'abx': '$%04X,x', 'aby': '$%04X,y', 'ind': '($%04X)'}


def main():
    path, bank, lo, hi = sys.argv[1], int(sys.argv[2]), int(sys.argv[3], 16), int(sys.argv[4], 16)
    data = open(path, 'rb').read()
    rev = {}
    for mn, modes in OPS.items():
        for mode, op in modes.items():
            rev[op] = (mn, mode)
    base = bank * 4096
    rd = lambda a: data[(base + (a & 0xFFF)) % len(data)]
    pc = lo
    while pc < hi:
        b = rd(pc)
        if b not in rev:
            print('%04X  %02X        .byte' % (pc, b))
            pc += 1
            continue
        mn, mode = rev[b]
        n = SIZE[mode]
        ops = [rd(pc + i) for i in range(1, n)]
        if mode == 'rel':
            arg = '$%04X' % ((pc + 2 + (ops[0] - 256 if ops[0] > 127 else ops[0])) & 0xFFFF)
        elif n == 2:
            arg = FMT2[mode] % ops[0]
        elif n == 3:
            arg = FMT3[mode] % (ops[0] | ops[1] << 8)
        else:
            arg = ''
        print('%04X  %-9s %s %s' % (pc, ' '.join('%02X' % x for x in [b] + ops), mn, arg))
        pc += n


if __name__ == '__main__':
    main()
