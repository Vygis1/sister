"""A TLB test for the N64's CPU: an N64 ROM image that maps pages and uses them.

    python tools/n64/n64tlbtest.py [build/n64tlb/TLBTEST.N64]

krom's tests take TLB refill misses but never map a page. This one does, and
leaves every result in a register, so tools/n64/n64rtltests.py --rom compares the
RTL with the model instruction by instruction. It covers:
  - TLBWI, TLBR (each field read back), TLBP (a hit, an ASID miss, a global hit)
  - 4 kB, 16 kB and 1 MB pages, both halves of an entry
  - global entries and ASID matching
  - loads and stores through the TLB, read back through KSEG0
  - a store to a clean page (TLB Modified), a valid bit clear (TLB Invalid),
    no entry at all (TLB Refill, at the 64-bit vector since Status.KX is set),
    and a miss in a branch delay slot
  - instruction fetch from a mapped page, and a fetch that misses
The exception handlers read Cause, EPC, BadVAddr, Context, XContext and EntryHi
into registers -- that is the check -- then step past the faulting instruction
(both it and the branch, if it was in a delay slot), or for a fetch that faulted,
return through RA.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))   # mipsasm
from mipsasm import *  # noqa: E402,F401,F403

C0_INDEX, C0_ENTRYLO0, C0_ENTRYLO1, C0_CONTEXT, C0_PAGEMASK = 0, 2, 3, 4, 5
C0_BADV, C0_ENTRYHI, C0_STATUS, C0_CAUSE, C0_EPC, C0_XCONTEXT = 8, 10, 12, 13, 14, 20


class N64Asm(Asm):
    def dmfc0(self, rt, rd): self._emit((0x10 << 26) | (0x01 << 21) | (rt << 16) | (rd << 11))
    def dmtc0(self, rt, rd): self._emit((0x10 << 26) | (0x05 << 21) | (rt << 16) | (rd << 11))
    def tlbr(self):  self._emit(0x42000001)
    def tlbwi(self): self._emit(0x42000002)
    def tlbp(self):  self._emit(0x42000008)
    def eret(self):  self._emit(0x42000018)
    def ld(self, rt, off, base): self._i(0x37, base, rt, off)
    def sd(self, rt, off, base): self._i(0x3F, base, rt, off)
    def dsll32(self, rd, rt, sh): self._r(0, 0, rt, rd, sh & 31, 0x3C)


def lo(pa, v=1, d=1, g=0, c=3):
    """an EntryLo: the page's physical address and its bits"""
    return ((pa >> 12) << 6) | (c << 3) | (d << 2) | (v << 1) | g


def build():
    a = N64Asm(org=0x80000000)
    # --- the vectors: the entry, the 64-bit TLB refill, the general one ---------------
    a.j('main'); a.nop()
    while a.pc < 0x80000080: a.nop()
    a.j('refill'); a.nop()
    while a.pc < 0x80000180: a.nop()
    a.j('general'); a.nop()
    while a.pc < 0x80000400: a.nop()          # 0x300.. is where the boot leaves its values

    # --- the handlers ---------------------------------------------------------------
    for name in ('refill', 'general'):
        a.label(name)
        a.mfc0(K0, C0_CAUSE)
        a.dmfc0(K1, C0_EPC)
        a.dmfc0(T8, C0_BADV)
        a.dmfc0(T9, C0_CONTEXT)
        a.dmfc0(T9, C0_XCONTEXT)
        a.dmfc0(T9, C0_ENTRYHI)
        a.addiu(S7, S7, 1)                      # exceptions taken
        # a fetch that faulted: BadVAddr is EPC; go back to whoever called it
        a.bne(T8, K1, name + '_data'); a.nop()
        a.dmtc0(RA, C0_EPC)
        a.j(name + '_out'); a.nop()
        a.label(name + '_data')
        a.addiu(K1, K1, 4)
        a.bgez(K0, name + '_set'); a.nop()      # Cause.BD (bit 31) clear
        a.addiu(K1, K1, 4)                      # in a delay slot: skip the branch too
        a.label(name + '_set')
        a.dmtc0(K1, C0_EPC)
        a.label(name + '_out')
        a.nop(); a.nop()
        a.eret()

    # --- the test -----------------------------------------------------------------
    a.label('main')
    a.ori(S7, ZERO, 0)

    def entry(index, va, asid, mask, lo0, lo1):
        a.li(T0, index); a.mtc0(T0, C0_INDEX)
        a.li(T0, va & 0xFFFFE000); a.ori(T0, T0, asid)   # sign-extended: kseg2 gets region 3
        a.dmtc0(T0, C0_ENTRYHI)
        a.li(T0, mask); a.mtc0(T0, C0_PAGEMASK)
        a.li(T0, lo0); a.mtc0(T0, C0_ENTRYLO0)
        a.li(T0, lo1); a.mtc0(T0, C0_ENTRYLO1)
        a.nop(); a.tlbwi(); a.nop()

    # 0: 4 kB pages at 0x00010000, global; the odd page is read-only
    entry(0, 0x00010000, 0, 0, lo(0x00200000, g=1), lo(0x00201000, d=0, g=1))
    # 1: 16 kB pages at 0x00020000, ASID 5 only; the odd page is not valid
    entry(1, 0x00020000, 5, 0x6000, lo(0x00210000), lo(0x00214000, v=0))
    # 2: 4 kB pages at 0xC0000000 (kseg2), global: code goes here
    entry(2, 0xC0000000, 0, 0, lo(0x00220000, g=1), lo(0x00221000, g=1))
    # 3: 1 MB pages at 0x00400000, global
    entry(3, 0x00400000, 0, 0x1FE000, lo(0x00300000, g=1), lo(0x00500000, g=1))
    # 4: the same VPN as 1 with another ASID, mapping elsewhere
    entry(4, 0x00020000, 7, 0x6000, lo(0x00230000), lo(0x00234000))
    a.li(T0, 0); a.mtc0(T0, C0_PAGEMASK)

    # TLBR: every entry's fields back
    for i in range(5):
        a.li(T0, i); a.mtc0(T0, C0_INDEX); a.nop(); a.tlbr(); a.nop()
        a.dmfc0(T1, C0_ENTRYHI); a.dmfc0(T2, C0_ENTRYLO0); a.dmfc0(T3, C0_ENTRYLO1); a.dmfc0(T4, C0_PAGEMASK)

    # ASID 0 from here on
    a.li(T0, 0); a.dmtc0(T0, C0_ENTRYHI)

    # entry 0: store and load through it, read back through KSEG0
    a.li(S0, 0x00010000)
    a.li(T0, 0x12345678); a.sw(T0, 0x10, S0)
    a.lw(T1, 0x10, S0)
    a.li(S1, 0x80200000); a.lw(T2, 0x10, S1)
    a.li(T0, 0x0BADF00D); a.sw(T0, 0x24, S1)        # through KSEG0 into the odd page's frame...
    a.li(S1, 0x80201000); a.sw(T0, 0x24, S1)
    a.lw(T3, 0x1024, S0)                            # ...and out through the TLB
    a.sw(T0, 0x1024, S0)                            # the odd page is clean: TLB Modified
    a.lbu(T4, 0x1027, S0)
    a.lh(T5, 0x0012, S0)
    a.li(T0, 0x1111); a.sd(T0, 0x18, S0); a.ld(T6, 0x18, S0)

    # entry 1: ASID 5 only. With ASID 0 it misses; with 5 it hits; its odd page is invalid
    a.li(S0, 0x00020000)
    a.lw(T1, 0x40, S0)                              # refill (wrong ASID)
    a.li(T0, 5); a.dmtc0(T0, C0_ENTRYHI); a.nop(); a.nop()
    a.li(T0, 0x55AA55AA); a.sw(T0, 0x40, S0); a.lw(T1, 0x40, S0)
    a.li(S1, 0x80210000); a.lw(T2, 0x40, S1)
    a.lw(T3, 0x4040, S0)                            # odd page: TLB Invalid (general vector)
    a.sw(T0, 0x4044, S0)                            # and on a store
    # entry 4: same VPN, ASID 7
    a.li(T0, 7); a.dmtc0(T0, C0_ENTRYHI); a.nop(); a.nop()
    a.li(T0, 0x77777777); a.sw(T0, 0x40, S0); a.sw(T0, 0x4040, S0)
    a.li(S1, 0x80230000); a.lw(T2, 0x40, S1)
    a.li(S1, 0x80234000); a.lw(T3, 0x40, S1)
    a.li(T0, 0); a.dmtc0(T0, C0_ENTRYHI); a.nop(); a.nop()

    # entry 3: 1 MB pages
    a.li(S0, 0x00400000)
    a.li(T0, 0xCAFE0001); a.sw(T0, 0x00, S0)
    a.li(T0, 0xCAFE0002); a.li(S2, 0x00480000); a.sw(T0, 0x10, S2)   # even page, half way in
    a.li(S2, 0x00500000); a.li(T0, 0xCAFE0003); a.sw(T0, 0x20, S2)   # odd page
    a.li(S1, 0x80300000); a.lw(T1, 0x00, S1)
    a.li(S1, 0x80380000); a.lw(T2, 0x10, S1)
    a.li(S1, 0x80500000); a.lw(T3, 0x20, S1)
    a.li(S2, 0x005FFFF0); a.sw(T0, 0x0, S2); a.lw(T4, 0x0, S2)       # the end of the odd page
    a.li(S2, 0x00600000); a.lw(T5, 0x0, S2)         # past it: refill

    # no entry at all, and a miss in a delay slot
    a.li(S0, 0x01000000)
    a.lw(T1, 0x8, S0)
    a.beq(ZERO, ZERO, 'after_slot')
    a.lw(T2, 0xC, S0)                               # in the delay slot
    a.nop()
    a.label('after_slot')
    a.addiu(T3, ZERO, 0x33)

    # TLBP: entry 1 with ASID 5; with ASID 0 (no match); entry 2 (global) with any
    a.li(T0, 0x00020000 | 5); a.dmtc0(T0, C0_ENTRYHI); a.nop(); a.tlbp(); a.nop(); a.mfc0(T1, C0_INDEX)
    a.li(T0, 0x00020000); a.dmtc0(T0, C0_ENTRYHI); a.nop(); a.tlbp(); a.nop(); a.mfc0(T2, C0_INDEX)
    a.li(T0, 0xC0000000 | 9); a.dmtc0(T0, C0_ENTRYHI); a.nop(); a.tlbp(); a.nop(); a.mfc0(T3, C0_INDEX)
    a.li(T0, 0x00400000); a.dmtc0(T0, C0_ENTRYHI); a.nop(); a.tlbp(); a.nop(); a.mfc0(T4, C0_INDEX)
    a.li(T0, 0); a.dmtc0(T0, C0_ENTRYHI)

    # code in a mapped page: copy a routine to its frame (uncached), then call it
    a.la(T0, 'routine'); a.li(T1, 0xA0220000)
    for i in range(4):
        a.lw(T2, 4 * i, T0); a.sw(T2, 4 * i, T1)
    a.lw(T2, 0, T1)                                 # wait for the stores to land
    a.li(V0, 40)
    a.li(T0, 0xC0000000); a.jalr(T0); a.nop()
    a.addiu(V1, V0, 0)
    a.li(T0, 0xC0001000); a.jalr(T0); a.nop()       # the odd page: the same code, not copied there
    a.li(T0, 0xC0100000); a.jalr(T0); a.nop()       # no entry: a refill on the fetch
    a.addiu(V1, V1, 1)

    a.label('done')
    a.j('done'); a.nop()

    a.label('routine')
    a.addiu(V0, V0, 2)
    a.jr(RA)
    a.addiu(V0, V0, 1)
    a.nop()
    return a.words()


def rom(words):
    """an N64 ROM image: a header whose entry point is 0x80000000, the code at 0x1000"""
    hdr = bytearray(0x1000)
    hdr[0:4] = bytes((0x80, 0x37, 0x12, 0x40))
    hdr[8:12] = (0x80000000).to_bytes(4, 'big')
    hdr[0x20:0x34] = b'TLB TEST'.ljust(20, b' ')
    body = b''.join(w.to_bytes(4, 'big') for w in words)
    return bytes(hdr) + body.ljust(0x10000, b'\0')


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..', '..', 'build', 'n64tlb', 'TLBTEST.N64')
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    open(out, 'wb').write(rom(build()))
    print(out)


if __name__ == '__main__':
    main()
