"""The N64's boot ROM: our own, in place of the PIF ROM and the cartridge's IPL3.

    python tools/n64/n64bootrom.py            writes rtl/n64_boot_rom.v

It does what the boot leaves behind, without any of Nintendo's code:
  - Status as IPL3 leaves it (241000E0);
  - the game's first megabyte copied from the cartridge to RDRAM at its entry
    point (the cartridge header's word at 8), a doubleword at a time;
  - which boot chip (CIC) the cartridge has, from its boot code's CRC32: 6103 and 6106
    games go 1 and 2 MB below the header's entry point, and each chip has its seed;
  - the values IPL3 leaves in low memory: TV type (NTSC), ROM base, reset type,
    the seed, version, and the RDRAM size (8 MB);
  - the registers the game may look at: s4 = TV type, s6 = CIC seed, sp;
  - a jump to the entry point.

The same program runs in tb_vr4300 (tools/n64/n64sim.py) and on the board
(n64_top's PIF ROM), so a trace of either starts in the same place.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..'))   # mipsasm
from mipsasm import Asm, ZERO, T0, T1, T2, T3, T4, T5, T6, T7, T8, T9, SP, S0, S4, S6, S7, A0, A1  # noqa: E402
from n64model import CICS  # noqa: E402  (the boot chips, by their boot code's CRC32)

STATUS_AFTER_IPL3 = 0x241000E0
COPY_BYTES = 1 << 20


def program():
    a = Asm(org=0xBFC00000)
    a.lui(T0, STATUS_AFTER_IPL3 >> 16); a.ori(T0, T0, STATUS_AFTER_IPL3 & 0xFFFF); a.mtc0(T0, 12)
    a.lui(S7, 0xB000)                                # the cartridge, uncached
    # Which boot chip (CIC) the cartridge has: the CRC32 of its boot code (ROM 0x40-0xFFF),
    # bit by bit (a third of a million instructions: a few milliseconds). It sets the seed
    # left in s6 and how far below the header's entry point the game goes (6103: 1 MB, 6106:
    # 2 MB) -- Super Smash Bros. is a 6103 and started a megabyte too high.
    a.lui(T6, 0xEDB8); a.ori(T6, T6, 0x8320)          # t6 = the polynomial (reflected)
    a.addiu(T0, ZERO, -1)                            # t0 = crc
    a.addiu(T2, S7, 0x40)                            # t2 = the boot code
    a.ori(T4, ZERO, (0x1000 - 0x40) // 4)            # t4 = words left
    a.label('cword')
    a.lw(T5, 0, T2); a.nop()
    a.ori(T3, ZERO, 24)                              # t3 = the byte's shift: 24, 16, 8, 0
    a.label('cbyte')
    a.srlv(T1, T5, T3); a.andi(T1, T1, 0xFF)
    a.xor(T0, T0, T1)
    a.ori(A0, ZERO, 8)
    a.label('cbit')
    a.andi(T1, T0, 1); a.subu(T1, ZERO, T1); a.and_(T1, T1, T6)
    a.srl(T0, T0, 1); a.xor(T0, T0, T1)
    a.addiu(A0, A0, -1)
    a.bne(A0, ZERO, 'cbit'); a.nop()
    a.addiu(T3, T3, -8)
    a.bgez(T3, 'cbyte'); a.nop()
    a.addiu(T2, T2, 4)
    a.addiu(T4, T4, -1)
    a.bne(T4, ZERO, 'cword'); a.nop()
    a.nor(T0, T0, ZERO)                              # t0 = the CRC32
    # the seed (s0, kept for s6) and the offset (t9): 6102's unless the CRC says otherwise
    a.ori(S0, ZERO, 0x3F); a.or_(T9, ZERO, ZERO)
    for crc, (cic, seed, back) in sorted(CICS.items()):
        if seed == 0x3F and back == 0:
            continue
        a.lui(T1, crc >> 16); a.ori(T1, T1, crc & 0xFFFF)
        a.bne(T0, T1, 'not%d' % cic); a.nop()
        a.ori(S0, ZERO, seed)
        a.lui(T9, back >> 16)
        a.label('not%d' % cic)
    a.lw(T1, 8, S7); a.nop()                         # the entry point
    a.subu(T1, T1, T9)                               # (less the chip's offset)
    # destination: the entry point's physical address, through KSEG1
    a.lui(T2, 0x1FFF); a.ori(T2, T2, 0xFFFF)
    a.and_(T3, T1, T2)
    a.lui(T2, 0xA000)
    a.or_(T3, T3, T2)                                # t3 = dest
    a.addiu(T2, S7, 0x1000)                          # t2 = source: ROM + 0x1000
    a.lui(T4, (COPY_BYTES // 8) >> 16); a.ori(T4, T4, (COPY_BYTES // 8) & 0xFFFF)
    a.label('copy')
    a._i(0x37, T2, T5, 0)                            # ld t5, 0(t2)
    a.nop()
    a._i(0x3F, T3, T5, 0)                            # sd t5, 0(t3)
    a.addiu(T2, T2, 8)
    a.addiu(T4, T4, -1)
    a.bne(T4, ZERO, 'copy')
    a.addiu(T3, T3, 8)                               # (delay slot)
    # low memory, as IPL3 leaves it
    a.lui(A0, 0xA000)
    for off, val in ((0x300, 1), (0x304, 0), (0x308, 0xB0000000), (0x30C, 0),
                     (0x310, None), (0x314, 0), (0x318, 0x00800000)):
        if val is None:
            a.sw(S0, off, A0)                        # (the seed)
        else:
            a.li(T0, val)
            a.sw(T0, off, A0)
    # registers
    a.lui(SP, 0xA400); a.ori(SP, SP, 0x1FF0)
    a.ori(S4, ZERO, 1); a.or_(S6, S0, ZERO)
    a.or_(T0, T1, ZERO)
    a.jr(T0); a.nop()
    return a.words()


def main():
    """A Verilog module, not a hex file: a case table needs no file path in
    simulation or synthesis, and 43 words cost a handful of LUTs."""
    words = program()
    out = os.path.join(HERE, '..', '..', 'rtl', 'n64_boot_rom.v')
    lines = ['// n64_boot_rom.v - GENERATED by tools/n64/n64bootrom.py; edit that, not this.',
             '// The N64 boot ROM: our own, where the PIF ROM sits (see the script).',
             '`default_nettype none',
             'module n64_boot_rom (input wire [6:0] a, output reg [31:0] q);',
             '	always @(*) begin',
             '		case (a)']
    for i, w in enumerate(words):
        lines.append("		7'd%d: q = 32'h%08x;" % (i, w))
    lines += ["		default: q = 32'h00000000;", '		endcase', '	end', 'endmodule', '`default_nettype wire', '']
    open(out, 'w').write(chr(10).join(lines))
    print('%d words -> %s' % (len(words), out))


if __name__ == '__main__':
    main()
