"""A Game Boy Advance file as the hex sim/tb_gba.v reads.
    python tools/gba/gbahex.py game.gba build/game.hex        halfwords, one a line (the cartridge)
    python tools/gba/gbahex.py -w bios.bin build/bios.hex     32-bit words (the BIOS)
"""
import struct
import sys


def main():
    args = sys.argv[1:]
    words = False
    if args and args[0] == '-w':
        words = True; args = args[1:]
    data = open(args[0], 'rb').read()
    if words:
        data += b'\0' * ((4 - len(data) % 4) % 4)
        out = ['%08x' % w for w in struct.unpack('<%dI' % (len(data) // 4), data)]
    else:
        data += b'\0' * (len(data) % 2)
        out = ['%04x' % w for w in struct.unpack('<%dH' % (len(data) // 2), data)]
    open(args[1], 'w').write('\n'.join(out) + '\n')
    print('%s: %d bytes -> %s' % (args[0], len(data), args[1]))


if __name__ == '__main__':
    main()
