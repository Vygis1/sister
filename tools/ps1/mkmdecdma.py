"""mkmdecdma.py - sim/roms/ps1/mdecdma.hex + mdecdma_data.hex for tb_ps1_mdecdma: a movie frame through
the MDEC the way Syphon Filter's player sends it (libpress DecDCTin / DecDCTout): the tables written
to 1F801820h, the frame's run-length words by DMA0 in 32-word blocks, the picture read back by DMA1
in 20 slices of 1920 words, each slice started only when the last one finished -- with an
ordering-table clear on channel 6 started beside each slice, so the MDEC channels have to step
aside for it. The frame is the first one of Syphon Filter's 989 logo, captured in DuckStation
(build/ps1mdec/syphon_*.bin, NOT in the tree -- game data: the quantisation tables, the scale table, the frame). Writes 1F80A000
when all 20 slices finished, 1F80A004 when one timed out.
    python tools/ps1/mkmdecdma.py"""
import os, sys, struct
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..'))
from mipsasm import *
ROOT = os.path.join(HERE, '..', '..')
def words(name):
    d = open(os.path.join(ROOT, 'build', 'ps1mdec', name), 'rb').read()
    return list(struct.unpack('<%dI' % (len(d) // 4), d))
qt, sc, fr = words('syphon_qt.bin'), words('syphon_sc.bin'), words('syphon_f0.bin')
QT, SC, FR, OUT, OT = 0x10000, 0x10100, 0x20000, 0x80000, 0x30000
SLICE, SLICES = 1920, 20
a = Asm(org=0xBFC00000)
a.lui(T0, 0x1F80)
a.li(T1, 0x80000000); a.sw(T1, 0x1824, T0)          # MDEC reset
a.li(T1, 0x60000000); a.sw(T1, 0x1824, T0)          # DMA0 / DMA1 requests on
for base, n in ((QT, len(qt)), (SC, len(sc))):        # the tables, by the processor
    a.li(T2, 0xA0000000 | base); a.li(T3, n)
    a.label('tb%x' % base)
    a.lw(T1, 0, T2); a.addiu(T2, T2, 4); a.addiu(T3, T3, -1)
    a.sw(T1, 0x1820, T0)
    a.bne(T3, ZERO, 'tb%x' % base); a.nop()
a.lw(T1, 0x10F0, T0); a.li(T3, 0x0888_8888); a.or_(T1, T1, T3); a.sw(T1, 0x10F0, T0)   # DPCR: all on
a.li(T1, fr[0]); a.sw(T1, 0x1820, T0)               # the decode command
a.li(T1, FR + 4); a.sw(T1, 0x1080, T0)               # DMA0: the words after it
a.li(T1, ((len(fr) - 1) // 32) << 16 | 32); a.sw(T1, 0x1084, T0)
a.li(T1, 0x01000201); a.sw(T1, 0x1088, T0)
a.li(S0, OUT); a.li(S1, SLICES)
a.label('slice')
a.sw(ZERO, 0x1098, T0)                               # (as DecDCTout: CHCR1 = 0 first)
a.sw(S0, 0x1090, T0)
a.li(T1, (SLICE // 32) << 16 | 32); a.sw(T1, 0x1094, T0)
a.li(T1, 0x01000200); a.sw(T1, 0x1098, T0)
a.li(T1, OT + 4 * 255); a.sw(T1, 0x10E0, T0)         # an OTC beside it
a.li(T1, 256); a.sw(T1, 0x10E4, T0)
a.li(T1, 0x11000002); a.sw(T1, 0x10E8, T0)
a.li(T4, 400000)
a.label('wait')
a.lw(T1, 0x1098, T0); a.lui(T3, 0x0100); a.and_(T1, T1, T3)
a.beq(T1, ZERO, 'load'); a.nop()
a.addiu(T4, T4, -1)
a.bne(T4, ZERO, 'wait'); a.nop()
a.li(T5, 0x1F80A004); a.sw(ZERO, 0, T5)
a.label('hang'); a.j('hang'); a.nop()
a.label('next')
a.label('load')
# the slice to VRAM, as the player's callback does (LoadImage: GP0 A0h, then DMA2 in blocks)
a.li(T1, 0x04000002); a.sw(T1, 0x1814, T0)          # GP1(04h): DMA to GP0
a.li(T1, 0xA0000000); a.sw(T1, 0x1810, T0)
a.sw(ZERO, 0x1810, T0)                               # at (0,0)
a.li(T1, (240 << 16) | 16); a.sw(T1, 0x1810, T0)    # 16 x 240
a.sw(S0, 0x10A0, T0)
a.li(T1, (SLICE // 16) << 16 | 16); a.sw(T1, 0x10A4, T0)
a.li(T1, 0x01000201); a.sw(T1, 0x10A8, T0)
a.li(T1, SLICE * 4); a.addu(S0, S0, T1)
a.addiu(S1, S1, -1)
a.bne(S1, ZERO, 'slice'); a.nop()
a.li(T5, 0x1F80A000); a.sw(ZERO, 0, T5)
a.label('hang2'); a.j('hang2'); a.nop()
prog = a.words()
out = os.path.join(ROOT, 'sim', 'roms', 'ps1')
open(os.path.join(out, 'mdecdma.hex'), 'w').write('\n'.join('%08x' % x for x in prog) + '\n')
# RAM image: "address word" lines for the bench
with open(os.path.join(out, 'mdecdma_data.hex'), 'w') as f:
    for base, ws in ((QT, qt), (SC, sc), (FR, fr)):
        for i, w in enumerate(ws): f.write('%06x %08x\n' % (base + 4 * i, w))
# what must come out: the model's words (DMA1 only re-orders them inside RAM)
sys.path.insert(0, HERE)
import mdec
m = mdec.Mdec()
for ws in (qt, sc, fr):
    for w in ws: m.write0(w)
got = []
while not (m.status() & 0x80000000): got.append(m.read0())
open(os.path.join(out, 'mdecdma_sum.txt'), 'w').write('%d %08x\n' % (len(got), sum(got) & 0xFFFFFFFF))
print('%d program words; the model makes %d words, sum %08x' % (len(prog), len(got), sum(got) & 0xFFFFFFFF))
