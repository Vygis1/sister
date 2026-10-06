"""dsprec.py - what the model's S-DSP was told while a ROM ran, and every sample it made, for
sim/tb_snes_dsp.v to replay into rtl/wip/snes_dsp.v and compare.

    python tools/snes/dsprec.py ROM.sfc [--frames N] [OUT.vec]

Lines of the file:
    M aaaa vv        a write to sound RAM (the SPC700's)
    W aa vv          a write to a DSP register ($F3)
    S                make a sample, then
    E l r x ...      what the model made: left, right (16-bit), ENDX, ENVX 0-7, OUTX 0-7
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import snes  # noqa: E402


def main():
    args = sys.argv[1:]
    rom = open(args[0], 'rb').read()
    frames = int(args[args.index('--frames') + 1]) if '--frames' in args else 120
    out = [a for a in args[1:] if a.endswith('.vec')]
    out = out[0] if out else os.path.join(HERE, '..', '..', 'build', 'dsp.vec')
    s = snes.Snes(rom)
    apu, dsp = s.apu, s.apu.dsp
    log = []
    aw0, dw0, ds0 = apu.write, dsp.write, dsp.sample

    def aw(a, v):
        aw0(a, v)
        log.append('M %04x %02x' % (a, apu.ram[a]))

    def dw(a, v):
        if not a & 0x80:
            log.append('W %02x %02x' % (a, v))
        dw0(a, v)

    def ds():
        log.append('S')
        ds0()
        l, r = dsp.out[-1]
        regs = dsp.r
        log.append('E %x %x %x %s %s' % (l & 0xFFFF, r & 0xFFFF, regs[0x7C],
                                         ' '.join('%x' % regs[(k << 4) | 8] for k in range(8)),
                                         ' '.join('%x' % regs[(k << 4) | 9] for k in range(8))))
    apu.write, dsp.write, dsp.sample = aw, dw, ds
    apu.spc.wr = aw                    # (the SPC700 writes through this)
    s.run_frames(frames, render_last=0)
    s._catch_up_apu()
    with open(out, 'w') as f:
        f.write('\n'.join(log) + '\n')
    print('%d records, %d samples -> %s' % (len(log), log.count('S'), out))


if __name__ == '__main__':
    main()
