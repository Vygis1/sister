"""krom's RDP tests through rtl/n64_rdp2.v alone (tools/n64/n64rdpsim.py, sim/tb_n64_rdp.v),
each checked line for line against the model.

    python tools/n64/n64rdprtl.py [FILTER ...]
"""
import glob
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..', '..')
KROM = os.path.join(ROOT, 'sim', 'roms', 'n64', 'krom', 'RDP')


def main():
    filters = [a for a in sys.argv[1:] if not a.startswith('--')]
    roms = sorted(glob.glob(os.path.join(KROM, '**', '*.N64'), recursive=True))
    good = bad = 0
    for rom in roms:
        name = os.path.splitext(os.path.basename(rom))[0]
        if filters and not any(f.lower() in name.lower() for f in filters):
            continue
        t0 = time.time()
        # (120 VI frames: a still test has drawn by then; an animated one would go on for ever)
        cap = subprocess.run([sys.executable, os.path.join(HERE, 'n64rdpsim.py'), rom, '--frames', '120'], capture_output=True, text=True)
        p = os.path.join(ROOT, 'sim', 'n64d', 'rtl_lines.hex')
        if os.path.exists(p):
            os.remove(p)
        sim = subprocess.run(['bash', './tools/sim.sh', 'tb_n64_rdp'], cwd=ROOT, capture_output=True, text=True)
        chk = subprocess.run([sys.executable, os.path.join(HERE, 'n64rdpsim.py'), '--check'], capture_output=True, text=True)
        ok = chk.returncode == 0
        good += ok; bad += not ok
        tb = [l for l in sim.stdout.split('\n') if 'tb_n64_rdp:' in l]
        print('%-44s %s  %s | %s | %s  %3.0f s' % (name, 'OK  ' if ok else 'FAIL', cap.stdout.strip().split('\n')[-1],
                                                 tb[-1].strip() if tb else 'no bench result',
                                                 chk.stdout.strip().split('\n')[0], time.time() - t0))
        sys.stdout.flush()
    print('%d OK, %d failing' % (good, bad))


if __name__ == '__main__':
    main()
