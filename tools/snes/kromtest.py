"""kromtest.py - every krom (PeterLemon/SNES) test ROM that ships a screenshot of the same name,
run on the model (tools/snes/snes.py) and compared with it.

    python tools/snes/kromtest.py [FILTER] [--frames N]

Writes each picture to build/snes_krom/NAME.png; prints the differing pixels per test.
"""
import glob
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import snes  # noqa: E402

ROOT = os.path.join(HERE, '..', '..', 'sim', 'roms', 'snes', 'krom', 'SNES-master')
OUT = os.path.join(HERE, '..', '..', 'build', 'snes_krom')
# the tests whose screenshot was taken after pressing buttons: (pad 1 held, frames)
HELD = {'MosaicMode3': (0x0010, 144), 'MosaicMode5': (0x0010, 144)}   # (R to mosaic size 16)


def main():
    args = sys.argv[1:]
    frames = int(args[args.index('--frames') + 1]) if '--frames' in args else 40
    filt = [a for a in args if not a.startswith('--') and not a.isdigit()]
    os.makedirs(OUT, exist_ok=True)
    ok = total = 0
    for sfc in sorted(glob.glob(os.path.join(ROOT, '**', '*.sfc'), recursive=True)):
        stem = os.path.splitext(os.path.basename(sfc))[0]
        png = os.path.join(os.path.dirname(sfc), stem + '.png')
        if not os.path.exists(png):
            continue
        rel = os.path.relpath(sfc, ROOT)
        if filt and not any(f.lower() in rel.lower() for f in filt):
            continue
        t0 = time.time()
        rom = open(sfc, 'rb').read()
        try:
            s = snes.Snes(rom)
            joy, n = HELD.get(stem, (0, frames))
            s.joy1 = joy
            s.run_frames(n)
            img = s.image(*snes.ref_size(png))
            snes.save_png(img, os.path.join(OUT, stem + '.png'))
            bad, n = snes.compare(img, png)
            res = '%6d differ' % bad
        except Exception as e:                          # noqa: BLE001
            bad, res = 1, 'ERROR %s: %s' % (type(e).__name__, e)
        total += 1
        ok += bad == 0
        print('%-70s %s  (%.0f s)' % (rel, res, time.time() - t0), flush=True)
    print('%d of %d match their screenshot' % (ok, total))


if __name__ == '__main__':
    main()
