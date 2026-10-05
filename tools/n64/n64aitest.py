"""An AI test for the N64: buffers queued, played and replaced, with every
sample distinct, so the RTL's sequence of samples can be held against the
model's one for one.

    python tools/n64/n64aitest.py [build/n64ai/AITEST.N64]

Buffer A (16 samples) crosses an 8 kB boundary. B (8 samples), queued behind
it, ends exactly on one: the AI's address counter carries into bit 13 a sample
late, so that carry is still pending when C (queued once A has gone and there
is room) starts, and C plays from 8 kB above its address (filled with its own
pattern so that shows). tb_n64_top writes every
sample the AI takes to sim/n64/ai.trace; the model keeps them in ai_samples.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))   # mipsasm
from mipsasm import *  # noqa: E402,F401,F403
from n64tlbtest import N64Asm, rom  # noqa: E402

A, A_LEN = 0x00101FE0, 0x40
B, B_LEN = 0x00111FE0, 0x20  # ends at 0x112000
C, C_LEN = 0x00120000, 0x20
QUIRK = C + 0x2000           # where C's first sample really comes from

FILLS = ((QUIRK, 8, 0xE0000000), (A, 16, 0xA0000000), (B, 8, 0xB0000000), (C, 8, 0xD0000000))


def build():
    a = N64Asm(org=0x80000000)
    a.j('main'); a.nop()
    while a.pc < 0x80000400: a.nop()
    a.label('main')
    for base, n, pat in FILLS:
        a.li(T0, base | 0xA0000000)
        for i in range(n):
            a.li(T1, pat + i * 0x00010001)
            a.sw(T1, 4 * i, T0)
    a.lw(T1, 0, T0)                                # the stores have landed
    a.li(S0, 0xA4500000)                           # the AI
    a.li(T1, 200); a.sw(T1, 0x10, S0)              # AI_DACRATE: a sample every 201 video clocks
    a.li(T1, A); a.sw(T1, 0x00, S0); a.li(T1, A_LEN); a.sw(T1, 0x04, S0)
    a.li(T1, B); a.sw(T1, 0x00, S0); a.li(T1, B_LEN); a.sw(T1, 0x04, S0)
    a.lw(T2, 0x0C, S0)                             # AI_STATUS: full
    a.li(T1, 1); a.sw(T1, 0x08, S0)                # AI_CONTROL: on
    a.label('wait_room')                           # until A is done and the queue has room
    a.lw(T2, 0x0C, S0); a.bltz(T2, 'wait_room'); a.nop()
    a.sw(ZERO, 0x0C, S0)                           # acknowledge the interrupt
    a.li(T1, C); a.sw(T1, 0x00, S0); a.li(T1, C_LEN); a.sw(T1, 0x04, S0)
    a.label('wait_idle')                           # until everything has played
    a.lw(T2, 0x0C, S0); a.sll(T2, T2, 1); a.bltz(T2, 'wait_idle'); a.nop()
    a.lw(T3, 0x0C, S0)
    a.label('done')
    a.j('done'); a.nop()
    return a.words()


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..', '..', 'build', 'n64ai', 'AITEST.N64')
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    open(out, 'wb').write(rom(build()))
    print(out)


if __name__ == '__main__':
    main()
