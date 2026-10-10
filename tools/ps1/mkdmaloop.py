"""mkdmaloop.py - sim/roms/ps1/dmaloop.hex, the program tb_ps1_dmaloop runs: a GPU linked list
whose one node points at itself (Syphon Filter builds one at its title screen), then an
ordering-table clear on channel 6 that must finish while the list goes round, then the list
stopped from CHCR. Writes 1F80A000 when the clear finished, 1F80A004 when it timed out, 1F80A008 when the table
is wrong."""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
from mipsasm import *
a = Asm(org=0xBFC00000)
a.lui(T0, 0x1F80)                       # I/O
a.lui(T1, 0xA000)                       # RAM, uncached
a.li(T2, 0x02001000); a.sw(T2, 0x1000, T1)     # the node: 2 words, next = itself
a.li(T2, 0xE3000000); a.sw(T2, 0x1004, T1)
a.li(T2, 0xE4000000); a.sw(T2, 0x1008, T1)
a.li(T2, 0x04000002); a.sw(T2, 0x1814, T0)     # GP1(04): DMA CPU->GP0
a.lw(T2, 0x10F0, T0); a.li(T3, 0x08000800); a.or_(T2, T2, T3); a.sw(T2, 0x10F0, T0)   # DPCR: 2 and 6 on
a.li(T2, 0x1000); a.sw(T2, 0x10A0, T0); a.sw(ZERO, 0x10A4, T0)
a.li(T2, 0x01000401); a.sw(T2, 0x10A8, T0)    # channel 2, linked list: goes round for ever
for _ in range(40): a.nop()
a.li(T2, 0x203C); a.sw(T2, 0x10E0, T0)        # OTC: 16 slots ending at 0x2000
a.li(T2, 16); a.sw(T2, 0x10E4, T0)
a.li(T2, 0x11000002); a.sw(T2, 0x10E8, T0)
a.li(T4, 20000)                               # wait for it, as libgpu's ClearOTag does
a.label('wait')
a.lw(T2, 0x10E8, T0); a.lui(T3, 0x0100); a.and_(T2, T2, T3)
a.beq(T2, ZERO, 'done'); a.nop()
a.addiu(T4, T4, -1)
a.bne(T4, ZERO, 'wait'); a.nop()
a.li(T2, 0x401); a.sw(T2, 0x10A8, T0)
a.li(T5, 0x1F80A004); a.sw(ZERO, 0, T5)
a.label('hang'); a.j('hang'); a.nop()
a.label('done')
a.li(T2, 0x401); a.sw(T2, 0x10A8, T0)        # stop the list, as ResetGraph(1) does
for _ in range(40): a.nop()
a.lw(T2, 0x2000, T1); a.li(T3, 0x00FFFFFF); a.bne(T2, T3, 'bad'); a.nop()   # the table really cleared
a.lw(T2, 0x203C, T1); a.li(T3, 0x00002038); a.bne(T2, T3, 'bad'); a.nop()
a.li(T5, 0x1F80A000); a.sw(ZERO, 0, T5)
a.label('hang2'); a.j('hang2'); a.nop()
a.label('bad')
a.li(T5, 0x1F80A008); a.sw(ZERO, 0, T5)
a.label('hang3'); a.j('hang2'); a.nop()
w = a.words()
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'sim', 'roms', 'ps1', 'dmaloop.hex')
open(out, 'w').write('\n'.join('%08x' % x for x in w) + '\n')
print('%d words -> %s' % (len(w), out))
