r"""A Game Boy ROM as $readmemh wants it: one byte per line.

    python tools/gb/gbhex.py build/gb-test-roms/cpu_instrs/individual/06-ld\ r,r.gb sim/roms/gb/06.hex

sim/roms is gitignored; the ROMs are other people's.
"""
import os
import sys


def main():
    src, dst = sys.argv[1], sys.argv[2]
    data = open(src, 'rb').read()
    os.makedirs(os.path.dirname(dst) or '.', exist_ok=True)
    with open(dst, 'w') as f:
        for b in data:
            f.write('%02x\n' % b)
    print('%s: %d bytes, mapper byte $%02x, ROM size byte $%02x, RAM size byte $%02x, title %r'
          % (dst, len(data), data[0x147], data[0x148], data[0x149], data[0x134:0x144].rstrip(b'\0')))


if __name__ == '__main__':
    main()
