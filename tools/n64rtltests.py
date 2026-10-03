"""krom's test ROMs through the RTL CPU (sim/tb_vr4300.v), checked against the model.

    python tools/n64rtltests.py [--only NAME] [--nowaits] [--rom PATH]

--rom runs one ROM of our own instead of krom's set (tools/n64tlbtest.py's).

For each ROM:
  1. tools/n64sim.py prepares RDRAM, the boot stub, and the model's trace;
  2. the bench runs the RTL to the end (FINISH1), with random memory waits;
  3. the traces must agree up to the first read of the VI's current line --
     the only place they may part, since the model counts instructions and the
     bench counts clocks, so their wait loops spin differently;
  4. the screens both leave must be identical.

Writes build/n64rtl/NAME.png (the RTL's screen) and a summary line per ROM.
"""
import glob
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..')
sys.path.insert(0, HERE)
import n64model  # noqa: E402

KROM = os.path.join(ROOT, 'sim', 'roms', 'n64', 'krom')
OUT = os.path.join(ROOT, 'build', 'n64rtl')
SIMDIR = os.path.join(ROOT, 'sim', 'n64')
VI_POLL = 0x8C890010          # lw t1, VI_V_CURRENT_LINE(a0): krom's WaitScanline


def model_steps(rom):
    """how far the model runs before it is done (the trace is that long)"""
    m = n64model.N64(open(rom, 'rb').read())
    m.stub_boot()
    n64model.run(m, 20_000_000)
    return m.cpu.instructions


def trace_check():
    a = open(os.path.join(SIMDIR, 'model.trace')).read().split('\n')
    b = open(os.path.join(SIMDIR, 'rtl.trace')).read().split('\n')
    n = min(len(a), len(b))
    # one trace stopping early is agreement when it is a prefix of the other and
    # both end spinning on the same address (a test that ends in a loop, and a
    # bench that stops on a clock budget)
    a_loop = set(l.split()[0] for l in [l for l in a if l][-8:])
    b_end = [l for l in b if l][-1:] or ['']
    spin = bool(b_end[0]) and b_end[0].split()[0] in a_loop
    for i in range(n):
        if a[i] != b[i]:
            # allowed only on the VI line read: is the model's instruction there the poll?
            pc = int(a[i].split()[0], 16) if a[i] and a[i][0] != 'X' else None
            word = None
            if pc is not None:
                rom = open(os.path.join(SIMDIR, 'rom.path')).read().strip()
                m = n64model.N64(open(rom, 'rb').read())
                m.fast_boot()
                word = m.read(pc & 0x1FFFFFFF, 4)
            if (a[i] == '' or b[i] == '') and spin:
                return i + 1, True, a[i], b[i]
            return i + 1, word == VI_POLL, a[i], b[i]
    return n, True, '', ''


def main():
    only = sys.argv[sys.argv.index('--only') + 1] if '--only' in sys.argv else None
    waits = '' if '--nowaits' in sys.argv else 'WAITS1'
    os.makedirs(OUT, exist_ok=True)
    roms = sorted(glob.glob(os.path.join(KROM, 'CPUTest', 'CPU', '**', '*.N64'), recursive=True))
    roms += sorted(glob.glob(os.path.join(KROM, 'CPUTest', 'CP1', '**', '*.N64'), recursive=True))
    # the exception and COP0 tests too (not the ones that need a timer interrupt
    # or the VI interrupt: the bench has neither yet)
    roms += sorted(r for r in glob.glob(os.path.join(KROM, 'CPUTest', 'Exceptions', '**', '*.N64'), recursive=True)
                   if not any(k in r for k in ('Compare', 'VIIntr')))
    if '--rom' in sys.argv:
        roms = [os.path.abspath(sys.argv[sys.argv.index('--rom') + 1])]
    good = bad = 0
    for rom in roms:
        name = os.path.splitext(os.path.basename(rom))[0]
        if only and only.lower() not in name.lower():
            continue
        if 'TIMING' in name:
            continue                      # counts cycles: meaningful on the board only
        t0 = time.time()
        steps = model_steps(rom)
        subprocess.run([sys.executable, os.path.join(HERE, 'n64sim.py'), rom, '--steps', str(steps)],
                       check=True, capture_output=True)
        # a run that did not happen must not be judged on the last run's files
        for stale in ('rtl.trace', 'rtl_rdram.hex'):
            if os.path.exists(os.path.join(SIMDIR, stale)):
                os.remove(os.path.join(SIMDIR, stale))
        sim = subprocess.run(['bash', './tools/sim.sh', 'tb_vr4300', 'STEPS%d' % (steps * 3), 'FINISH1'] + ([waits] if waits else []),
                             cwd=ROOT, capture_output=True, text=True)
        if 'instructions retired' not in sim.stdout or not os.path.exists(os.path.join(SIMDIR, 'rtl_rdram.hex')):
            bad += 1
            why = [l for l in sim.stdout.splitlines() if 'ERROR' in l or 'TIMED OUT' in l][:2]
            print('%-12s FAIL  the bench did not finish: %s' % (name, ' | '.join(why) or 'no output'))
            sys.stdout.flush()
            continue
        line = [l for l in sim.stdout.split('\n') if 'tb_vr4300:' in l]
        at, ok_trace, ma, rb = trace_check()
        fin = subprocess.run([sys.executable, os.path.join(HERE, 'n64sim.py'), '--final', '--png',
                              os.path.join(OUT, name + '.png')], capture_output=True, text=True)
        same = fin.returncode == 0
        ok = ok_trace and same
        good += ok; bad += not ok
        print('%-12s %s  trace agrees to line %-8d %s  screen %s  %4.0f s'
              % (name, 'OK  ' if ok else 'FAIL', at,
                 '(then the VI poll)' if ok_trace else '(model %s / rtl %s)' % (ma, rb),
                 'same' if same else 'DIFFERENT', time.time() - t0))
        sys.stdout.flush()
    print('%d OK, %d failing' % (good, bad))


if __name__ == '__main__':
    main()
