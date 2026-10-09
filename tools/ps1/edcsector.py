"""edcsector.py - a synthetic Mode 2 Form 1 sector with its EDC, for sim/tb_edc.v.

    python tools/ps1/edcsector.py sim/roms/ps1/edc_sector.hex

The EDC is the table-driven CRC (reflected 0xD8018001, start 0) that matches every Gran Turismo 2
sector sampled on the PC (634 Form 1, 36 Form 2 of 670); the bench checks the drive's bit-serial
edc8 (rtl/ps1_cdrom.v) against it. Random data: no game data in the tree.
"""
import random
import struct
import sys

T = []
for i in range(256):
    x = i
    for _ in range(8):
        x = (x >> 1) ^ 0xD8018001 if x & 1 else x >> 1
    T.append(x)


def edc(b):
    c = 0
    for v in b:
        c = (c >> 8) ^ T[(c ^ v) & 0xFF]
    return c


def main():
    random.seed(2026)
    s = bytearray(b'\x00' + b'\xff' * 10 + b'\x00' + bytes([0x00, 0x02, 0x16, 0x02])
                  + bytes([0, 0, 8, 0, 0, 0, 8, 0]) + bytes(random.randrange(256) for _ in range(2048)))
    s += struct.pack('<I', edc(s[16:0x818]))
    s += bytes(2352 - len(s))
    with open(sys.argv[1], 'w') as f:
        f.write('\n'.join('%02x' % b for b in s) + '\n')
    print('EDC %08x' % edc(s[16:0x818]))


if __name__ == '__main__':
    main()
