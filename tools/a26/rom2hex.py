#!/usr/bin/env python3
"""Turn a 2600 cartridge image into what sim/tb_a26.v loads.

    python tools/a26/rom2hex.py game.bin [--scheme N] [--gate] [--frames N] [--out sim/roms/a2600]

Writes <out>/test.hex (one byte a line, for $readmemh into the console's 32 KB
cartridge block RAM) and <out>/test_cfg.txt with four lines: the image size in
bytes, the bank-switching scheme code (0 = decide by size; the codes are listed
at the top of rtl/a26_top.v), the gate flag and the number of frames to run. The gate flag tells the bench
the image is tools/a26/kernels/test.asm and that its pixel and RAM checks apply;
for anything else the bench only measures and dumps a frame.
"""
import os
import sys


def main():
    args = sys.argv[1:]
    scheme, gate, out, frames = 0, 0, 'sim/roms/a2600', 4
    if '--scheme' in args:
        i = args.index('--scheme')
        scheme = int(args[i + 1])
        del args[i:i + 2]
    if '--gate' in args:
        gate = 1
        args.remove('--gate')
    if '--frames' in args:
        i = args.index('--frames')
        frames = int(args[i + 1])
        del args[i:i + 2]
    if '--out' in args:
        i = args.index('--out')
        out = args[i + 1]
        del args[i:i + 2]
    (src,) = args
    data = open(src, 'rb').read()
    if len(data) not in (2048, 4096, 8192, 12288, 16384, 32768):
        raise SystemExit('%s: %d bytes is not a cartridge size this console takes' % (src, len(data)))
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, 'test.hex'), 'w') as f:
        for b in data:
            f.write('%02X\n' % b)
    with open(os.path.join(out, 'test_cfg.txt'), 'w') as f:
        f.write('%d\n%d\n%d\n%d\n' % (len(data), scheme, gate, frames))
    print('%s: %d bytes -> %s/test.hex (scheme %d, gate %d, %d frames)' % (src, len(data), out, scheme, gate, frames))


if __name__ == '__main__':
    main()
