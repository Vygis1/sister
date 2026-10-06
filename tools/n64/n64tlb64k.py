"""SM64's own TLB use, as a CPU test: goddard maps its heap with two global entries of 64 kB
pages (PageMask 0x1E000) at 0x04000000 and 0x04020000 (the model's TLB at the Mario head,
tools/n64/n64model.py), the way libultra's osMapTLB writes them, then reads and writes
through them. A miss there hung SM64 on the board (4978e51's TLB). Compared with the model
instruction by instruction:  python tools/n64/n64rtltests.py --rom build/n64tlb/TLB64K.N64
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
from mipsasm import *  # noqa: E402,F401,F403
from n64tlbtest import N64Asm, rom, lo, C0_INDEX, C0_ENTRYLO0, C0_ENTRYLO1, C0_PAGEMASK, C0_ENTRYHI  # noqa: E402


def build():
    a = N64Asm(org=0x80000000)
    a.j('main'); a.nop()
    while a.pc < 0x80000400: a.nop()
    a.label('main')

    def maptlb(index, pm, va, even, odd):
        # (libultra osMapTLB: EntryHi saved, the fields, TLBWI, four nops, EntryHi back)
        a.mfc0(T7, C0_ENTRYHI)
        a.li(T0, index); a.mtc0(T0, C0_INDEX)
        a.li(T0, pm); a.mtc0(T0, C0_PAGEMASK)
        a.li(T0, va); a.mtc0(T0, C0_ENTRYHI)
        a.li(T0, lo(even, g=1)); a.mtc0(T0, C0_ENTRYLO0)
        a.li(T0, lo(odd, g=1)); a.mtc0(T0, C0_ENTRYLO1)
        a.nop(); a.tlbwi(); a.nop(); a.nop(); a.nop(); a.nop()
        a.mtc0(T7, C0_ENTRYHI)

    maptlb(0, 0x1E000, 0x04000000, 0x00390000, 0x003A0000)
    maptlb(1, 0x1E000, 0x04020000, 0x003B0000, 0x003C0000)
    # values through KSEG0 into the frames
    a.li(S1, 0x80390000); a.li(T0, 0x0000D1D4); a.sw(T0, 0x650, S1)
    a.li(S1, 0x803A0000); a.li(T0, 0x11112222); a.sw(T0, 0x123C, S1)
    a.li(S1, 0x803B0000); a.li(T0, 0x33334444); a.sw(T0, 0x0008, S1)
    a.li(S1, 0x803C0000); a.li(T0, 0x55556666); a.sw(T0, 0xFFFC, S1)
    # and out through the TLB: even and odd halves of both entries
    a.li(S0, 0x04000650); a.lw(S2, 0, S0)
    a.li(S0, 0x0401123C); a.lw(S3, 0, S0)
    a.li(S0, 0x04020008); a.lw(S4, 0, S0)
    a.li(S0, 0x0403FFFC); a.lw(S5, 0, S0)
    # goddard's own pattern: the pointer through the stack, the load straight after
    a.li(SP, 0x80100000); a.li(A0, 0x04000650)
    a.sw(A0, 48, SP); a.sw(S0, 24, SP); a.lw(T6, 48, SP); a.nop(); a.lw(S6, 0, T6)
    # a store through it, read back through KSEG0
    a.li(T0, 0x77778888); a.li(S0, 0x04010010); a.sw(T0, 0, S0)
    a.li(S1, 0x803A0010); a.lw(S7, 0, S1)
    a.label('done')
    a.j('done'); a.nop()
    return a.words()


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..', '..', 'build', 'n64tlb', 'TLB64K.N64')
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    open(out, 'wb').write(rom(build()))
    print(out)


if __name__ == '__main__':
    main()
