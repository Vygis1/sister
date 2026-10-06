"""rtlframe.py - the whole-system RTL (sim/tb_snes_top.v) against the model: run a ROM N frames
in both, compare the last frame's 256 x 224 picture (column pairs averaged in 5-bit, as the
RTL hands them out).

    python tools/snes/rtlframe.py ROM.sfc [N]
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..', '..')
sys.path.insert(0, HERE)
import snes  # noqa: E402


def main():
    rom_path = os.path.abspath(sys.argv[1])
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 30
    open(os.path.join(ROOT, 'build', 'tb_snes_rom.txt'), 'w').write(rom_path.replace(chr(92), '/') + '\n')
    open(os.path.join(ROOT, 'build', 'tb_snes_frames.txt'), 'w').write('%d\n' % n)
    r = subprocess.run(['bash', './tools/simwip.sh', 'tb_snes_top'], cwd=ROOT, capture_output=True, text=True)
    print('\n'.join(l for l in r.stdout.splitlines() if 'tb_snes_top' in l or 'rom ' in l or 'frame ' in l))
    os.remove(os.path.join(ROOT, 'build', 'tb_snes_rom.txt'))
    os.remove(os.path.join(ROOT, 'build', 'tb_snes_frames.txt'))
    rtl = [int(l, 16) for l in open(os.path.join(ROOT, 'build', 'snes_rtl_frame.txt'))]
    s = snes.Snes(open(rom_path, 'rb').read())
    s.run_frames(n)
    bad = 0
    first = None
    for y in range(224):
        row = s.ppu.frame[2 * y]
        for x in range(256):
            a, b = row[2 * x], row[2 * x + 1]
            m = 0
            for sh in (0, 5, 10):
                m |= ((((a >> sh) & 31) + ((b >> sh) & 31)) >> 1) << sh
            if m != rtl[y * 256 + x]:
                bad += 1
                if first is None:
                    first = (x, y, rtl[y * 256 + x], m)
    print('%d of 57344 pixels differ%s' % (bad, '' if first is None else ' (first at %d,%d: rtl %04x model %04x)' % first))
    from PIL import Image
    im = Image.new('RGB', (256, 224))
    for i, c in enumerate(rtl):
        im.putpixel((i % 256, i // 256), tuple(((c >> sh) & 31) * 255 // 31 for sh in (0, 5, 10)))
    im.save(os.path.join(ROOT, 'build', 'snes_rtl_frame.png'))


if __name__ == '__main__':
    main()
