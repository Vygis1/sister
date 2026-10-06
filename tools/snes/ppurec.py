"""ppurec.py - what the model's PPU was told while a ROM ran, and what it drew, for
sim/tb_snes_ppu.v to replay into rtl/wip/snes_ppu.v and compare line by line.

    python tools/snes/ppurec.py ROM.sfc [--frames N] [--joy HEX] [OUT.vec]

Lines of the file:
    W aa vv     a write to $21aa (the CPU's or DMA's)
    R aa        a read of $21aa that moves something ($2138 $2139 $213A $213B $2137 $213F ...)
    L v f       draw line v, field f (only in the last frame), then
    E p0 .. p511   the 512 pixels the model drew there (BGR555, hex)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import snes  # noqa: E402


def main():
    args = sys.argv[1:]
    rom = open(args[0], 'rb').read()
    frames = int(args[args.index('--frames') + 1]) if '--frames' in args else 40
    out = [a for a in args[1:] if a.endswith('.vec')]
    out = out[0] if out else os.path.join(HERE, '..', '..', 'build', 'ppu.vec')
    s = snes.Snes(rom)
    if '--joy' in args:
        s.joy1 = int(args[args.index('--joy') + 1], 16)
    p = s.ppu
    log = []
    w0, r0, rl0 = p.write, p.read, p.render_line

    def w(r, v):
        log.append('W %02x %02x' % (r & 0xFF, v))
        w0(r, v)

    def rd(r, h=0, v=0):
        if 0x2134 <= r <= 0x213F:
            log.append('R %02x' % (r & 0xFF))
        return r0(r, h, v)

    def rl(v):
        rl0(v)
        if 1 <= v <= p.lines():
            row = p.frame[2 * (v - 1) + (p.field if p.setini & 1 else 0)]
            log.append('L %x %x' % (v, p.field))
            log.append('E ' + ' '.join('%x' % c for c in row))
    p.write, p.read, p.render_line = w, rd, rl
    s.run_frames(frames, render_last=1)
    with open(out, 'w') as f:
        f.write('\n'.join(log) + '\n')
    print('%d records -> %s' % (len(log), out))


if __name__ == '__main__':
    main()
