"""tekseq.py - Tekken 2's vertex transform loop as a self-checking program, for tb_ps1_tekseq.

Tekken 2 (SLUS-00213) projects every model through one tight loop (game code at
80072e84..80072f18): the first three vertices go into the GTE with LWC2 and RTPT runs straight
behind the last of them; after that it is MTC2 x6, NOP, RTPT, then -- while the GTE is still
busy -- six LWs of the next triple, and SWC2 of SXY0/1/2 into a table in the scratchpad
(0x1F800100, 4 bytes a vertex), the third SWC2 in the branch's delay slot. Every polygon is then
built out of that table. On the board ~90% of Tekken 2's polygons came out with exactly one
corner hundreds of pixels off, the same wrong corners shared between neighbours: wrong entries
in that table.

This runs the game's own instruction sequence, from RAM through the instruction cache as the
game does, over SETS objects (each its own rotation, translation and vertex list), and compares
every table entry with tools/ps1/gte.py's answer.

    python tools/ps1/tekseq.py sim/roms/ps1/tekseq [SETS] [IRQ]   -> tekseq_rom.hex, tekseq_ram.hex
                                                   (IRQ: a timer interrupt every IRQ clocks)
    ./tools/sim.sh tb_ps1_tekseq

Results (RAM): 0x1000 first failing set + 1 (0 = none), 0x1004 sets run, 0x1008 the entry
stored, 0x100C the entry expected, 0x1010 failures, 0x1014 the failing vertex's index, 0x1018 interrupts taken.
"""
import os
import random
import struct
import sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..'))
sys.path.insert(0, HERE)
from mipsasm import *  # noqa: E402,F401,F403
from gte import GTE  # noqa: E402

RTPT = 0x0280030
CODE = 0x80010000        # the loop, in RAM (cached, through the instruction cache)
DATA = 0x80040000        # the sets: header + vertices + expected table
SPAD = 0x1F800100        # the game's table


def s16w(lo, hi):
    return ((hi & 0xFFFF) << 16) | (lo & 0xFFFF)


def make_sets(n, rng):
    sets = []
    for k in range(n):
        # a rotation-ish matrix (4.12), a translation putting the model in front of the camera
        m = [rng.randint(-4096, 4096) for _ in range(9)]
        tr = [rng.randint(-600, 600), rng.randint(-400, 400), rng.randint(1500, 6000)]
        cnt = rng.choice([3, 6, 7, 12, 23, 24, 30, 48])
        verts = [(rng.randint(-700, 700), rng.randint(-700, 700), rng.randint(-700, 700)) for _ in range(cnt)]
        g = GTE()
        g.write_ctrl(0, s16w(m[0], m[1])); g.write_ctrl(1, s16w(m[2], m[3])); g.write_ctrl(2, s16w(m[4], m[5]))
        g.write_ctrl(3, s16w(m[6], m[7])); g.write_ctrl(4, m[8] & 0xFFFF)
        g.write_ctrl(5, tr[0] & 0xFFFFFFFF); g.write_ctrl(6, tr[1] & 0xFFFFFFFF); g.write_ctrl(7, tr[2] & 0xFFFFFFFF)
        g.write_ctrl(24, (160 << 16)); g.write_ctrl(25, (120 << 16)); g.write_ctrl(26, 600)
        want = []
        padded = verts + [(0, 0, 0)] * ((-cnt) % 3)
        for i in range(0, len(padded), 3):
            for j in range(3):
                x, y, z = padded[i + j]
                g.write_data(2 * j, s16w(x, y)); g.write_data(2 * j + 1, z & 0xFFFF)
            g.op(RTPT)
            want += [g.read_data(12), g.read_data(13), g.read_data(14)]
        sets.append((m, tr, verts, want[:cnt]))
    return sets


def build(nsets, seed=1, irq=0):
    rng = random.Random(seed)
    sets = make_sets(nsets, rng)
    # --- the data, from DATA: per set a header {next, count, ctl words RT0-4 TR0-2, expected ptr},
    # the vertex list as the game keeps it (count, then VXY/VZ pairs), the expected table
    data = []
    heads = []
    for m, tr, verts, want in sets:
        base = DATA + 4 * len(data)
        heads.append(base)
        hdr = [0, len(verts), s16w(m[0], m[1]), s16w(m[2], m[3]), s16w(m[4], m[5]), s16w(m[6], m[7]),
               m[8] & 0xFFFF, tr[0] & 0xFFFFFFFF, tr[1] & 0xFFFFFFFF, tr[2] & 0xFFFFFFFF, 0]
        lst = [len(verts)]
        for x, y, z in verts:
            lst += [s16w(x, y), z & 0xFFFF]
        lst += [0] * 12                       # the loop's look-ahead reads past the end
        hdr[10] = base + 4 * (len(hdr) + len(lst))
        data += hdr + lst + want
    for i, h in enumerate(heads):             # link the headers
        data[(h - DATA) // 4] = heads[i + 1] if i + 1 < len(heads) else 0

    # --- the loop, in RAM
    a = Asm(org=CODE)
    a.li(S0, heads[0])          # the set
    a.li(S1, 0)                 # failures
    a.li(S2, 0)                 # sets run
    a.li(S4, 0)                 # first failing set + 1
    a.li(T5, 0x80001000)        # results
    a.li(S5, 0x1F801000)        # I/O
    a.label('set')
    for i in range(8):          # RT and TR
        a.lw(T0, 8 + 4 * i, S0); a.nop(); a.ctc2(T0, i)
    a.li(T0, 160 << 16); a.ctc2(T0, 24)
    a.li(T0, 120 << 16); a.ctc2(T0, 25)
    a.li(T0, 600); a.ctc2(T0, 26)
    a.addiu(T8, S0, 44)         # the vertex list (count first), right after the header
    a.lw(T9, 0, T8)
    a.nop()
    a.blez(T9, 'skip')
    a.nop()
    a.andi(V0, S2, 1)           # odd objects: the fighter loop
    a.bne(V0, ZERO, 'fighter')
    a.nop()
    # ---- Tekken 2, 80072e8c..80072f18, instruction for instruction ----
    a.lui(T6, 0x1F80)
    a.ori(T6, T6, 0x0100)
    a.lwc2(0, 4, T8); a.lwc2(1, 8, T8); a.lwc2(2, 12, T8)
    a.lwc2(3, 16, T8); a.lwc2(4, 20, T8); a.lwc2(5, 24, T8)
    a.cop2(RTPT)
    a.bgez(ZERO, 'tk_in')
    a.addiu(T8, T8, 28)
    a.label('tk_loop')
    a.mtc2(T0, 0); a.mtc2(T1, 1); a.mtc2(T2, 2); a.mtc2(T3, 3); a.mtc2(T4, 4); a.mtc2(T5, 5)
    a.nop()
    a.cop2(RTPT)
    a.label('tk_in')
    a.addi(T6, T6, 12)
    a.addi(T9, T9, -3)
    a.lw(T0, 0, T8); a.lw(T1, 4, T8); a.lw(T2, 8, T8); a.lw(T3, 12, T8); a.lw(T4, 16, T8); a.lw(T5, 20, T8)
    a.addi(T8, T8, 24)
    a.swc2(12, -12, T6)
    a.swc2(13, -8, T6)
    a.bgtz(T9, 'tk_loop')
    a.swc2(14, -4, T6)
    # ---- end of the game's loop ----
    a.j('tk_done')
    a.nop()
    # ---- Tekken 2's fighter loop, 800728a0..80072968: the same, plus each triple's SZ1-3 kept
    # (>> 4) as halfwords -- and the first of those MFC2s sits in the branch's delay slot, so
    # the MTC2 t0,VXY0 at the branch target must still see the vertex t0 was loaded with ----
    a.label('fighter')
    a.addiu(T8, T8, 4)
    a.lui(T6, 0x1F80)
    a.ori(T6, T6, 0x0100)       # (the game's table is at 1F800000; ours where the compare looks)
    a.lwc2(0, 0, T8); a.lwc2(1, 4, T8); a.lwc2(2, 8, T8)
    a.lwc2(3, 12, T8); a.lwc2(4, 16, T8); a.lwc2(5, 20, T8)
    a.nop()
    a.cop2(RTPT)
    a.addi(T7, T6, 0x200)       # (the game: 682; kept inside the scratchpad here)
    a.bgez(ZERO, 'fi_in')
    a.addiu(T8, T8, 24)
    a.label('fi_loop')
    a.mtc2(T0, 0); a.mtc2(T1, 1); a.mtc2(T2, 2); a.mtc2(T3, 3); a.mtc2(T4, 4); a.mtc2(T5, 5)
    a.mfc2(T0, 17); a.mfc2(T1, 18); a.mfc2(T2, 19)
    a.nop()
    a.cop2(RTPT)
    a.sra(T0, T0, 4); a.sra(T1, T1, 4); a.sra(T2, T2, 4)
    a.sh(T0, -6, T7); a.sh(T1, -4, T7); a.sh(T2, -2, T7)
    a.label('fi_in')
    a.addi(T6, T6, 12)
    a.addi(T7, T7, 6)
    a.addi(T9, T9, -3)
    a.lw(T0, 0, T8); a.lw(T1, 4, T8); a.lw(T2, 8, T8); a.lw(T3, 12, T8); a.lw(T4, 16, T8); a.lw(T5, 20, T8)
    a.addi(T8, T8, 24)
    a.swc2(12, -12, T6)
    a.swc2(13, -8, T6)
    a.swc2(14, -4, T6)
    a.bgtz(T9, 'fi_loop')
    a.mfc2(T0, 17)              # <- the delay slot
    a.mfc2(T1, 18); a.mfc2(T2, 19)
    a.sra(T0, T0, 4); a.sra(T1, T1, 4); a.sra(T2, T2, 4)
    a.sh(T0, -6, T7); a.sh(T1, -4, T7); a.sh(T2, -2, T7)
    a.label('tk_done')
    a.li(T5, 0x80001000)        # (the loop used t5 for vertex data)
    # compare the table with the expected one
    a.lw(T9, 4, S0)             # count
    a.lw(T7, 40, S0)            # expected
    a.li(T6, SPAD)
    a.li(A2, 0)                 # index
    a.label('cmp')
    a.lw(A0, 0, T6)
    a.lw(A1, 0, T7)
    a.nop()
    a.beq(A0, A1, 'cmp_ok')
    a.nop()
    a.addiu(S1, S1, 1)
    a.bne(S4, ZERO, 'cmp_ok')
    a.nop()
    a.addiu(S4, S2, 1)
    a.sw(A0, 8, T5)
    a.sw(A1, 12, T5)
    a.sw(A2, 0x14, T5)
    a.label('cmp_ok')
    a.addiu(T6, T6, 4)
    a.addiu(T7, T7, 4)
    a.addiu(A2, A2, 1)
    a.bne(A2, T9, 'cmp')
    a.nop()
    a.label('skip')
    # an ordering-table DMA (channel 6) on its own area, as a frame does, to share the bus
    a.li(V0, 0x800C0100); a.sw(V0, 0xE0, S5)
    a.li(V0, 48); a.sw(V0, 0xE4, S5)
    a.li(V0, 0x11000002); a.sw(V0, 0xE8, S5)
    a.addiu(S2, S2, 1)
    a.lw(S0, 0, S0)
    a.nop()
    a.bne(S0, ZERO, 'set')
    a.nop()
    a.sw(S4, 0, T5)
    a.sw(S2, 4, T5)
    a.sw(S1, 0x10, T5)
    a.li(V0, 0x1F800000)
    a.lw(V0, 0x3FC, V0)
    a.nop()
    a.sw(V0, 0x18, T5)          # interrupts taken
    a.li(V0, 0x1F80A000)        # the bench's end marker
    a.lw(V1, 0, V0)
    a.nop()
    a.label('done')
    a.j('done')
    a.nop()
    code = a.words()
    assert CODE + 4 * len(code) <= DATA

    # --- the ROM: coprocessor 2 on, jump to the loop
    r = Asm(org=0xBFC00000)
    r.j('main')
    r.nop()
    while r.pc < 0xBFC00180:
        r.nop()
    # the exception vector (BEV): acknowledge every interrupt, and -- as the BIOS's handler does --
    # return PAST a GTE command at EPC, which the R3000 has already sent to the GTE
    r.lui(K0, 0x1F80)
    r.sw(ZERO, 0x1070, K0)
    r.lw(K1, 0x3FC, K0)         # count them (the last scratchpad word)
    r.nop()
    r.addiu(K1, K1, 1)
    r.sw(K1, 0x3FC, K0)
    r.mfc0(K0, C0_EPC)
    r.nop()
    r.lw(K1, 0, K0)
    r.nop()
    r.srl(K1, K1, 24)
    r.andi(K1, K1, 0xFE)
    r.addiu(K1, K1, -0x4A)
    r.bne(K1, ZERO, 'ret')
    r.nop()
    r.addiu(K0, K0, 4)
    r.label('ret')
    r.jr(K0)
    r.rfe()
    r.label('main')
    r.li(V1, 0x1F800000)
    r.sw(ZERO, 0x3FC, V1)
    r.li(V1, 0x1F801000)
    r.li(V0, 0x08000000)        # DPCR: channel 6 on
    r.sw(V0, 0xF0, V1)
    if irq:
        # root counter 2 every `irq` clocks, interrupt at the target, repeating
        r.li(V0, irq); r.sw(V0, 0x128, V1)
        r.li(V0, 0x0058); r.sw(V0, 0x124, V1)
        r.li(V0, 0x40); r.sw(V0, 0x74, V1)        # I_MASK: timer 2
        r.sw(ZERO, 0x70, V1)
        r.li(V0, 0x40400401)                      # CU2, BEV, IM2, IEc
    else:
        r.li(V0, 0x40400000)                      # CU2, BEV
    r.mtc0(V0, C0_SR)
    r.nop()
    r.li(V0, CODE)
    r.jr(V0)
    r.nop()
    rom = r.words()
    assert len(rom) <= 1024

    ram = [0] * ((DATA - CODE) // 4) + data
    ram[:len(code)] = code
    return rom, ram, sum(len(s[2]) for s in sets)


def main():
    out = sys.argv[1]
    nsets = int(sys.argv[2]) if len(sys.argv) > 2 else 64
    irq = int(sys.argv[3]) if len(sys.argv) > 3 else 0      # a timer interrupt every IRQ clocks
    rom, ram, nv = build(nsets, irq=irq)
    with open(out + '_rom.hex', 'w') as f:
        f.write(''.join('%08x\n' % x for x in rom))
    with open(out + '_ram.hex', 'w') as f:
        f.write(''.join('%08x\n' % x for x in ram))
    print('%d sets, %d vertices; rom %d words, ram %d words (from %08x)' % (nsets, nv, len(rom), len(ram), CODE))


if __name__ == '__main__':
    main()
