r"""A PC Engine HuCard image as $readmemh wants it: one byte per line.

    python tools/pce/pcehex.py build/dl/pce_blox/20220408/GAME.pce sim/roms/pce/blox.hex

A 512-byte copier header (the size is 512 past a multiple of 8 kB) is dropped. US
TurboGrafx dumps with their data bits reversed are put right when the reset vector's bank
looks wrong the one way and right the other.
"""
import os
import sys


def load(src):
    data = open(src, 'rb').read()
    if len(data) % 8192 == 512:
        data = data[512:]
    # a bit-reversed dump: the reset vector at $1FFE of the first bank points into the
    # first 64 kB on a proper one
    def vec(d):
        return d[0x1FFE] | (d[0x1FFF] << 8)
    rev = bytes(int('{:08b}'.format(b)[::-1], 2) for b in data[:0x2000])
    if vec(data) < 0xE000 and vec(rev) >= 0xE000:
        data = bytes(int('{:08b}'.format(b)[::-1], 2) for b in data)
        print('bit-reversed dump put right')
    return data


def main():
    src, dst = sys.argv[1], sys.argv[2]
    data = load(src)
    os.makedirs(os.path.dirname(dst) or '.', exist_ok=True)
    with open(dst, 'w') as f:
        for b in data:
            f.write('%02x\n' % b)
    print('%s: %d bytes, reset vector %04x' % (dst, len(data), data[0x1FFE] | (data[0x1FFF] << 8)))


if __name__ == '__main__':
    main()
