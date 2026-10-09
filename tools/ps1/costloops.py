"""costloops.py - ps1-tests' own timing loops, for sim/tb_r3000_cost.v to measure the CPU pace
model's console cycles against the console's numbers:
    cpu/access-time  RAM lbu/lhu/lw loop, 100 reads:      5.21 / 5.30 / 5.14 cycles a read
    dma/chain-looping volatile g += i, 1000 iterations:   16.04 cycles an iteration
Each loop is run with a 'nop' baseline exactly as the test does (count down, bnez, nop).

    python tools/ps1/costloops.py sim/roms/mips/costloops.hex
"""
import os
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
from mipsasm import *  # noqa: E402,F401,F403


def build():
    a = Asm(org=0x80010000)
    a.li(T9, 0x00001F00)                 # marker store address: the bench notes ctime at each store here
    def mark(k):
        a.li(AT, k); a.sw(AT, 0, T9)
    a.li(A0, 0x80000000)
    # (1) nop baseline, 100
    mark(1); a.li(V0, 100); a.label('n1'); a.nop(); a.addiu(V0, V0, -1); a.bne(V0, ZERO, 'n1'); a.nop(); mark(2)
    # (2) lbu loop, 100 (the test: nop; addiu; lbu a0,0(v1); bnez; nop)
    a.li(V1, 0x80000000); a.li(V0, 100)
    a.label('b1'); a.nop(); a.addiu(V0, V0, -1); a.lbu(A1, 0, V1); a.bne(V0, ZERO, 'b1'); a.nop(); mark(3)
    # (3) lw loop, 100
    a.li(V0, 100)
    a.label('w1'); a.nop(); a.addiu(V0, V0, -1); a.lw(A1, 0, V1); a.bne(V0, ZERO, 'w1'); a.nop(); mark(4)
    # (4) volatile g += i, 1000
    a.li(T0, 0x80012C30); a.sw(ZERO, 0, T0); a.li(V1, 0); a.li(A2, 1000); mark(5)
    a.label('g1'); a.lw(V0, 0, T0); a.nop(); a.addu(V0, V0, V1); a.sw(V0, 0, T0); a.addiu(V1, V1, 1); a.bne(V1, A2, 'g1'); a.nop(); mark(6)
    a.label('done'); a.j('done'); a.nop()
    return a.words()


def main():
    w = build()
    with open(sys.argv[1], 'w') as f:
        f.write('\n'.join('%08x' % x for x in w) + '\n')
    print('%d words' % len(w))


if __name__ == '__main__':
    main()
