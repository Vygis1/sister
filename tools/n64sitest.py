"""An SI test for the N64: DMAs between RDRAM and PIF RAM from buffers that
are 8-aligned but not 16-aligned, so they straddle five DDR3 lines.

    python tools/n64sitest.py [build/n64si/SITEST.N64]

The program writes a joybus command block (controller 1's status and buttons,
the EEPROM's status) at 0x80001008, DMAs it into PIF RAM, DMAs PIF RAM out to
0x80002008, and does it twice (the second time into 0x80003018) with the SI
interrupt acknowledged in between. tb_n64_top runs it, and the RDRAM it leaves
is compared with the model's (see the end of this file).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mipsasm import *  # noqa: E402,F401,F403
from n64tlbtest import N64Asm, rom  # noqa: E402

BLOCK = bytes.fromhex(
    'ff'                      # padding
    '010300ffffff'            # controller 1: status (send 1, receive 3), room for it
    '01040100000000'          # controller 2: buttons (nothing plugged in there)
    '00'                      # controller 3: skip
    'fd'                      # controller 4: reset
    '010300ffffff'            # the cartridge: EEPROM status
    'fe').ljust(63, b'\0') + b'\x01'


def build():
    a = N64Asm(org=0x80000000)
    a.j('main'); a.nop()
    while a.pc < 0x80000400: a.nop()
    a.label('main')
    a.li(S0, 0xA4800000)                       # the SI
    for n, (src, dst) in enumerate(((0x80001008, 0x80002008), (0x80001008, 0x80003018))):
        # the command block, a word at a time
        a.li(T0, src | 0x20000000)             # uncached: it must be in RDRAM when the SI reads it
        for i in range(16):
            a.li(T1, int.from_bytes(BLOCK[4 * i:4 * i + 4], 'big'))
            a.sw(T1, 4 * i, T0)
        a.lw(T1, 0, T0)                        # the stores have landed
        a.li(T1, src & 0x1FFFFFFF); a.sw(T1, 0x00, S0)          # SI_DRAM_ADDR
        a.li(T1, 0x1FC007C0); a.sw(T1, 0x10, S0)                # SI_PIF_ADDR_WR64B: RDRAM to PIF
        a.label('w%d' % n)
        a.lw(T2, 0x18, S0); a.andi(T2, T2, 1); a.bne(T2, ZERO, 'w%d' % n); a.nop()
        a.sw(ZERO, 0x18, S0)                   # acknowledge
        a.li(T1, dst & 0x1FFFFFFF); a.sw(T1, 0x00, S0)
        a.li(T1, 0x1FC007C0); a.sw(T1, 0x04, S0)                # SI_PIF_ADDR_RD64B: PIF to RDRAM
        a.label('r%d' % n)
        a.lw(T2, 0x18, S0); a.andi(T2, T2, 1); a.bne(T2, ZERO, 'r%d' % n); a.nop()
        a.lw(T3, 0x18, S0)                     # the interrupt bit, before...
        a.sw(ZERO, 0x18, S0)
        a.lw(T4, 0x18, S0)                     # ...and after the acknowledge
        a.li(T0, 0xBFC007C4); a.lw(T5, 0, T0)  # PIF RAM read directly
    a.label('done')
    a.j('done'); a.nop()
    return a.words()


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..', 'build', 'n64si', 'SITEST.N64')
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    open(out, 'wb').write(rom(build()))
    print(out)


if __name__ == '__main__':
    main()
