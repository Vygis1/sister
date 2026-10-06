"""ppurtl.py - the RTL PPU (rtl/wip/snes_ppu.v) against the model on krom's PPU test ROMs: each
ROM run in the model (tools/snes/ppurec.py), its PPU traffic replayed into the RTL
(sim/tb_snes_ppu.v), every line of the last frame compared.

    python tools/snes/ppurtl.py [FILTER ...]
"""
import glob
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..', '..')
KROM = os.path.join(ROOT, 'sim', 'roms', 'snes', 'krom', 'SNES-master')
# frames to run, and the pad held (as kromtest.py)
SPECIAL = {'MosaicMode3': (144, '0010'), 'MosaicMode5': (144, '0010')}


def main():
    filt = [a.lower() for a in sys.argv[1:]]
    roms = sorted(glob.glob(os.path.join(KROM, 'PPU', '**', '*.sfc'), recursive=True))
    roms += [os.path.join(KROM, 'HelloWorld', 'HelloWorld.sfc')]
    ok = n = 0
    for rom in roms:
        rel = os.path.relpath(rom, KROM)
        if filt and not any(f in rel.lower() for f in filt):
            continue
        stem = os.path.splitext(os.path.basename(rom))[0]
        frames, joy = SPECIAL.get(stem, (40, None))
        cmd = [sys.executable, os.path.join(HERE, 'ppurec.py'), rom, '--frames', str(frames)]
        if joy:
            cmd += ['--joy', joy]
        subprocess.run(cmd, cwd=ROOT, capture_output=True)
        r = subprocess.run(['bash', './tools/simwip.sh', 'tb_snes_ppu'], cwd=ROOT, capture_output=True, text=True)
        res = [l for l in r.stdout.splitlines() if 'tb_snes_ppu:' in l or l.startswith('  line')]
        good = any('all checks passed' in l for l in res)
        n += 1
        ok += good
        print('%-70s %s' % (rel, 'ok   ' + res[0].split(':', 1)[1].strip() if good else 'FAIL ' + ' | '.join(res[:3])), flush=True)
    print('%d of %d match the model line for line' % (ok, n))


if __name__ == '__main__':
    main()
