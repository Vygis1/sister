"""krom's RSP tests through rtl/n64_rsp.v alone, each run of the RSP checked
against the model's (tools/n64/n64rspsim.py, sim/tb_n64_rsp.v).

    python tools/n64/n64rsptests.py [--only NAME]
"""
import glob
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..', '..')
KROM = os.path.join(ROOT, 'sim', 'roms', 'n64', 'krom', 'RSPTest')


def main():
    only = sys.argv[sys.argv.index('--only') + 1] if '--only' in sys.argv else None
    roms = sorted(glob.glob(os.path.join(KROM, '**', '*.N64'), recursive=True))
    good = bad = 0
    for rom in roms:
        name = os.path.splitext(os.path.basename(rom))[0]
        if only and only.lower() not in name.lower():
            continue
        t0 = time.time()
        prep = subprocess.run([sys.executable, os.path.join(HERE, 'n64rspsim.py'), rom], capture_output=True, text=True)
        for stale in ('rtl.trace', 'rtl_dmem.hex'):
            p = os.path.join(ROOT, 'sim', 'n64r', stale)
            if os.path.exists(p):
                os.remove(p)
        subprocess.run(['bash', './tools/sim.sh', 'tb_n64_rsp'], cwd=ROOT, capture_output=True, text=True)
        chk = subprocess.run([sys.executable, os.path.join(HERE, 'n64rspsim.py'), '--check'], capture_output=True, text=True)
        ok = chk.returncode == 0
        good += ok; bad += not ok
        print('%-22s %s  %s | %s  %3.0f s' % (name, 'OK  ' if ok else 'FAIL', prep.stdout.strip().split(chr(10))[-1],
                                         ' / '.join(chk.stdout.strip().split(chr(10))), time.time() - t0))
        sys.stdout.flush()
    print('%d OK, %d failing' % (good, bad))


if __name__ == '__main__':
    main()
