"""gt2seq.py - Gran Turismo 2's colour path as a self-checking loop, for tb_r3000_gt2.

GT2 writes a polygon's command word straight out of the GTE: it loads RGBC (colour + GPU command
code) right behind an RTPT, runs DPCS with IR0 = 0 -- whose result is RGBC unchanged -- and stores
the colour FIFO's RGB2 into the packet with SWC2 (game code at 80019b70..80019c44). On the board,
now and then a packet's command word came out as the PREVIOUS polygon's: a display list the GPU
then misread, and the game hung. This repeats that sequence with a new colour every time, three
ways of loading RGBC, and counts every stored word that is not the colour just loaded.

    python tools/ps1/gt2seq.py sim/roms/mips/gt2seq.hex [iterations]

Results (RAM): 0x1000 first failing iteration (0 = none), 0x1004 iterations run, 0x1008 the word
stored, 0x100C the word expected, 0x1010 failures, 0x1014 which variant failed first.
"""
import os
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
from mipsasm import *  # noqa: E402,F401,F403

RTPT, NCLIP, DPCS = 0x0280030, 0x1400006, 0x0780010


def build(iters, system=False):
    a = Asm(org=0xBFC00000)
    a.j('main')
    a.nop()
    while a.pc < 0xBFC00180:
        a.nop()
    # the exception vector (BEV set): the bench raises interrupts at random and drops the line
    # when one is taken. Like the BIOS's handler, it returns PAST a GTE command at EPC -- the
    # R3000 has already sent that command to the GTE when it takes the interrupt (k0/k1 are the
    # handler's own)
    a.mfc0(K0, C0_EPC)
    a.nop()
    a.lw(K1, 0, K0)
    a.nop()
    a.srl(K1, K1, 24)
    a.andi(K1, K1, 0xFE)
    a.addiu(K1, K1, -0x4A)
    a.bne(K1, ZERO, 'ret')
    a.nop()
    a.addiu(K0, K0, 4)
    a.label('ret')
    a.jr(K0)
    a.rfe()
    a.label('main')
    if system:
        # (tb_ps1_gt2sys: the whole console -- RAM through the caches and DDR3, the addresses
        # walking so loads miss, an ordering-table DMA every iteration on its own area)
        a.li(T2, 0x80040000)
        a.li(T0, 0x80080000)
        a.li(T5, 0x80001000)
        a.li(T9, 0x1F801000)    # I/O
        a.li(V0, 0x08000000)    # DPCR: channel 6 on
        a.sw(V0, 0xF0, T9)
    else:
        a.li(T2, 0x3000)            # colour source (8(t2))
        a.li(T0, 0x2000)            # packet (4(t0) is its command word)
        a.li(T5, 0x1000)            # results
    a.li(S0, 0x24000101)        # the colour + code, changed every iteration
    a.li(S1, 0)                 # failures
    a.li(S2, 0)                 # iterations
    a.li(S3, iters)
    a.li(S4, 0)                 # first failing iteration
    a.li(T6, 0x00010305)        # colour step
    a.li(T7, 0x00FFFFFF)
    a.li(T8, 0x24000000)
    # coprocessor 2 on (SR bit 30), BEV (22), interrupt line 0 unmasked (IM2, bit 10), enabled (IEc)
    a.li(V0, 0x40400000 if system else 0x40400401)
    a.mtc0(V0, C0_SR)
    a.nop()
    a.label('loop')
    for variant in range(3):
        # next colour: code 0x24, the colour bytes stepping (kept clear of saturation)
        a.addu(S0, S0, T6)
        a.and_(S0, S0, T7)
        a.or_(S0, S0, T8)
        a.sw(S0, 8, T2)
        a.mtc2(S2, 0); a.mtc2(S0, 1); a.mtc2(S2, 2); a.mtc2(S0, 3); a.mtc2(ZERO, 4); a.mtc2(S2, 5)
        a.cop2(RTPT)
        if variant == 0:                 # GT2: load, delay slot, move -- while RTPT runs
            a.lw(V0, 8, T2)
            a.nop()
            a.mtc2(V0, 6)
        elif variant == 1:               # straight from memory into the GTE
            a.lwc2(6, 8, T2)
        else:                            # a register already holding it, right behind the command
            a.mtc2(S0, 6)
        a.cfc2(V0, 31)
        a.mfc2(A1, 17); a.mfc2(A3, 18); a.mfc2(A2, 19)
        a.cop2(NCLIP)
        a.mfc2(V1, 24)
        a.addu(A0, A1, A3)
        a.mtc2(ZERO, 8)                  # IR0 = 0: DPCS gives RGBC back
        a.cop2(DPCS)
        a.lw(V1, 8, T2)
        a.srl(A0, V1, 30)
        a.swc2(22, 4, T0)                # the packet's command word
        a.lw(A0, 4, T0)
        a.nop()
        a.beq(A0, S0, 'ok%d' % variant)
        a.nop()
        a.addiu(S1, S1, 1)               # a failure: keep the first one's details
        a.bne(S4, ZERO, 'ok%d' % variant)
        a.nop()
        a.addiu(S4, S2, 1)
        a.sw(A0, 8, T5)
        a.sw(S0, 12, T5)
        a.li(V0, variant)
        a.sw(V0, 0x14, T5)
        a.label('ok%d' % variant)
        if system:
            # walk the source and the packet through RAM (64 kB each), and clear an ordering
            # table of 48 entries by DMA at 0x800C0000 + a little
            a.addiu(T2, T2, 0x34)
            a.addiu(T0, T0, 0x2C)
            a.li(V0, 0x800C0100)
            a.sw(V0, 0xE0, T9)
            a.li(V0, 48)
            a.sw(V0, 0xE4, T9)
            a.li(V0, 0x11000002)
            a.sw(V0, 0xE8, T9)
    if system:
        a.li(V0, 0x0000FFFF); a.and_(T2, T2, V0); a.lui(V0, 0x8004); a.or_(T2, T2, V0)
        a.li(V0, 0x0000FFFF); a.and_(T0, T0, V0); a.lui(V0, 0x8008); a.or_(T0, T0, V0)
    a.addiu(S2, S2, 1)
    a.bne(S2, S3, 'loop')
    a.nop()
    a.sw(S4, 0, T5)
    a.sw(S2, 4, T5)
    a.sw(S1, 0x10, T5)
    if system:
        a.li(V0, 0x1F80A000)    # the bench's end marker
        a.lw(V1, 0, V0)
        a.nop()
    a.label('done')
    a.j('done')
    a.nop()
    return a.words()


def main():
    out = sys.argv[1]
    iters = int(sys.argv[2]) if len(sys.argv) > 2 else 4000
    w = build(iters, system=(len(sys.argv) > 3 and sys.argv[3] == 'system'))
    with open(out, 'w') as f:
        for x in w:
            f.write('%08x\n' % x)
    print('%d words, %d iterations' % (len(w), iters))


if __name__ == '__main__':
    main()
