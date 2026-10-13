#!/usr/bin/env python3
"""Build the bank-switching gate for sim/tb_a26_bank.v.

    python tools/a26/bankgate.py [--out sim/roms/a2600]

For every cartridge scheme a26_top.v implements, assembles a small program that
switches banks the way the scheme's documentation says (AtariAge's
bankswitch_sizes.txt and Kevin Horton's "Atari 2600 Mappers" notes) and records
what it finds into RIOT RAM from $80 up, then writes $A5 to $9F to say it has
finished. Every bank carries an ID byte, so the RAM ends up holding the sequence
of banks the processor actually saw. The expected sequence follows from the
documents, not from the RTL.

Writes bank_<n>.hex (one byte a line) and bank_cases.txt, one case a line:
    <hex file index> <image bytes> <scheme code> <name> <count> <expected bytes...>

The 4K-bank schemes use the usual trick: the same code sits at the same address
in every bank, so after a hotspot access execution carries on at the next
instruction of the newly selected bank.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asm import Asm  # noqa: E402

DONE = """
    lda #$A5
    sta $9F
done:
    jmp done
"""


def assemble(src):
    return Asm().assemble(src)


def image(size, chunks):
    """chunks: list of (file offset, {addr: byte}, base addr)"""
    img = bytearray(size)
    for off, out, base in chunks:
        for a, b in out.items():
            img[off + a - base] = b
    return img


def bank4k(code, ident):
    """one 4K bank at $F000: code from $F200, the ID byte at $FE00, vectors"""
    src = """
    .org $F200
start:
    sei
    cld
    ldx #$FF
    txs
%s
%s
    .org $FE00
    .byte %d
    .org $FFFC
    .word start
    .word start
""" % (code, DONE, ident)
    return assemble(src)


def rec(n):
    return "    lda $FE00\n    sta $%02X\n" % (0x80 + n)


def hit(a):
    return "    lda $%04X\n" % a


def plain_4k_banks(nbanks, seq, extra='', extra_exp=()):
    """seq: hotspot addresses visited in order; a record before and after each"""
    code = rec(0)
    for i, a in enumerate(seq):
        code += hit(a) + rec(i + 1)
    code += extra
    return [(k * 4096, bank4k(code, k), 0xF000) for k in range(nbanks)]


def cases():
    out = []

    # 2K: the image mirrors into both halves of the 4K window
    src = """
    .org $F800
start:
    sei
    cld
    ldx #$FF
    txs
    lda $F600       ; the mirror of $FE00
    sta $80
    lda $FE00
    sta $81
%s
    .org $FE00
    .byte $2A
    .org $FFFC
    .word start
    .word start
""" % DONE
    out.append(('2K', 2048, 0, image(2048, [(0, assemble(src), 0xF800)]), [0x2A, 0x2A]))

    # 4K: the 6507 has 13 address lines, so $3E00 is $FE00
    src = """
    .org $F200
start:
    sei
    cld
    ldx #$FF
    txs
    lda $FE00
    sta $80
    lda $3E00
    sta $81
%s
    .org $FE00
    .byte $4B
    .org $FFFC
    .word start
    .word start
""" % DONE
    out.append(('4K', 4096, 0, image(4096, [(0, assemble(src), 0xF000)]), [0x4B, 0x4B]))

    # F8: power-up in the last bank (where every game keeps a reset vector)
    out.append(('F8', 8192, 0, image(8192, plain_4k_banks(2, [0xFFF8, 0xFFF9])), [1, 0, 1]))
    # F6
    out.append(('F6', 16384, 0, image(16384, plain_4k_banks(4, [0xFFF6, 0xFFF9, 0xFFF7, 0xFFF8])),
                [3, 0, 3, 1, 2]))
    # F4
    out.append(('F4', 32768, 0, image(32768, plain_4k_banks(8, [0xFFF4, 0xFFFB, 0xFFF6, 0xFFFA])),
                [7, 0, 7, 2, 6]))

    # FA: three banks and 256 bytes of RAM, write $1000-$10FF, read $1100-$11FF
    ram = """
    lda #$5A
    sta $F010
    lda #$C3
    sta $F0FF
    lda $F110
    sta $90
    lda $F1FF
    sta $91
"""
    out.append(('FA', 12288, 8, image(12288, plain_4k_banks(3, [0xFFF8, 0xFFFA, 0xFFF9], ram)),
                [2, 0, 2, 1] + [0] * 12 + [0x5A, 0xC3]))

    # Super Chip: 128 bytes, write $1000-$107F, read $1080-$10FF
    sc = """
    lda #$5A
    sta $F000
    lda #$C3
    sta $F07F
    lda $F080
    sta $90
    lda $F0FF
    sta $91
"""
    out.append(('F8SC', 8192, 9, image(8192, plain_4k_banks(2, [0xFFF8, 0xFFF9], sc)),
                [1, 0, 1] + [0] * 13 + [0x5A, 0xC3]))
    out.append(('F6SC', 16384, 10, image(16384, plain_4k_banks(4, [0xFFF7, 0xFFF9], sc)),
                [3, 1, 3] + [0] * 13 + [0x5A, 0xC3]))
    out.append(('F4SC', 32768, 11, image(32768, plain_4k_banks(8, [0xFFF5, 0xFFFB], sc)),
                [7, 1, 7] + [0] * 13 + [0x5A, 0xC3]))

    # FE: JSR to $Dxxx runs in the first 4K, RTS to $Fxxx returns to the second.
    # The same program in both banks; only the ID differs.
    src = """
    .org $F200
start:
    sei
    cld
    ldx #$FF
    txs
    jsr sub-$2000   ; $Dxxx: D5 of the new high byte is 0 -> the first 4K
    lda $FE00
    sta $81         ; back at $Fxxx -> the second 4K
    jsr sub         ; $Fxxx again: stays in the second 4K
%s
sub:
    lda $FE00
    sta $80,x       ; X counts the calls: $80, then $82
    inx
    inx
    rts
    .org $FE00
    .byte %%d
    .org $FFFC
    .word start
    .word start
""" % DONE
    # X starts at $FF after txs; reset it before the first call
    src = src.replace("    txs\n    jsr", "    txs\n    ldx #0\n    jsr", 1)
    fe = image(8192, [(0, assemble(src % 0), 0xF000), (4096, assemble(src % 1), 0xF000)])
    out.append(('FE', 8192, 5, fe, [0, 1, 1]))

    # E0: four 1K windows; the last fixed to the image's last 1K, the program there.
    # Each 1K slice carries its number at offset $200.
    src = """
    .org $FC00
start:
    sei
    cld
    ldx #$FF
    txs
    lda $FFE5       ; window 0 <- slice 5
    lda $F200
    sta $80
    lda $FFEA       ; window 1 <- slice 2
    lda $F600
    sta $81
    lda $FFF1       ; window 2 <- slice 1
    lda $FA00
    sta $82
    lda $FE00       ; window 3: always slice 7
    sta $83
    lda $FFE6       ; window 0 <- slice 6; windows 1 and 2 unchanged
    lda $F200
    sta $84
    lda $F600
    sta $85
%s
    .org $FE00
    .byte 7
    .org $FFFC
    .word start
    .word start
""" % DONE
    e0 = bytearray(8192)
    for k in range(7):
        e0[k * 1024 + 0x200] = k
    for a, b in assemble(src).items():
        e0[7 * 1024 + a - 0xFC00] = b
    out.append(('E0', 8192, 6, e0, [5, 2, 1, 7, 6, 2]))

    # 3F: a write anywhere in $00-$3F picks the 2K bank at $1000; $1800 is the
    # last 2K. A write to a TIA mirror at $40-$7F must not switch.
    src = """
    .org $F800
start:
    sei
    cld
    ldx #$FF
    txs
    lda #2
    sta $3F
    lda $F200
    sta $80
    lda #0
    sta $3F
    lda $F200
    sta $81
    lda $FA00
    sta $82
    lda #1
    sta $7F         ; a TIA mirror: no switch
    lda $F200
    sta $83
    sta $2D         ; A = 0 here; $2D is in $00-$3F: switches to bank 0
    lda #1
    sta $2E         ; to bank 1
    lda $F200
    sta $84
%s
    .org $FA00
    .byte 3
    .org $FFFC
    .word start
    .word start
""" % DONE
    t3 = bytearray(8192)
    for k in range(3):
        t3[k * 2048 + 0x200] = k
    for a, b in assemble(src).items():
        t3[3 * 2048 + a - 0xF800] = b
    out.append(('3F', 8192, 7, t3, [2, 0, 3, 0, 1]))
    return out


def main():
    args = sys.argv[1:]
    outdir = 'sim/roms/a2600'
    if '--out' in args:
        outdir = args[args.index('--out') + 1]
    os.makedirs(outdir, exist_ok=True)
    lines = []
    for i, (name, size, scheme, img, exp) in enumerate(cases()):
        assert len(img) == size, name
        with open(os.path.join(outdir, 'bank_%d.hex' % i), 'w') as f:
            for b in img:
                f.write('%02X\n' % b)
        lines.append('%d %d %d %s %d %s' % (i, size, scheme, name, len(exp), ' '.join('%d' % e for e in exp)))
    with open(os.path.join(outdir, 'bank_cases.txt'), 'w') as f:
        f.write('\n'.join(lines) + '\n')
    print('%d bank-switching cases -> %s' % (len(lines), outdir))


if __name__ == '__main__':
    main()
