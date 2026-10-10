"""dssuite.py - run ps1-tests discs in DuckStation and judge its TTY text as ps1suite judges ours.

The bar for our core (2026-10-10): pass what the reference emulators pass. This tells which console
results DuckStation itself does not reproduce, so they come off the list.

Needs DuckStation's TTY logging to a file: [BIOS] TTYLogging = true and [Logging] LogToFile = true,
LogLevel = Info in ~/Documents/DuckStation/settings.ini (the "I/TTY: " lines of duckstation.log).

  python tools/ps1/dssuite.py [NAME ...]        (default: every text test)
"""
import os, sys, subprocess, time, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ps1suite

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
DISCS = os.path.join(ROOT, 'build', 'ps1discs')
OUT = os.path.join(ROOT, 'build', 'dssuite')
LOG = os.path.expanduser('~/Documents/DuckStation/duckstation.log')
RUN_S = {'gpu_bandwidth': 150, 'cdrom_timing': 60, 'cdrom_getloc': 60, 'timers': 60, 'dma_chopping': 40}

def ds_exe():
    base = os.path.join(os.environ['LOCALAPPDATA'], 'Microsoft', 'WinGet', 'Packages')
    for p in glob.glob(os.path.join(base, 'Stenzek.DuckStation*', '**', 'duckstation*.exe'), recursive=True):
        return p
    raise SystemExit('DuckStation not found')

def run(name, secs):
    disc = os.path.join(DISCS, name + '.bin')
    p = subprocess.Popen([ds_exe(), disc])
    time.sleep(secs)
    subprocess.run(['taskkill', '/PID', str(p.pid), '/F'], capture_output=True)
    time.sleep(1.5)
    text = open(LOG, 'rb').read().decode('latin-1')
    # (a blank TTY line is logged as "I/TTY:" with nothing after it)
    return '\n'.join(l.split('I/TTY:', 1)[1][1:] for l in text.replace('\r', '').split('\n') if 'I/TTY:' in l)

def main():
    want = set(sys.argv[1:])
    os.makedirs(OUT, exist_ok=True)
    for name, ref_log, ref_vram in ps1suite.tests():
        if not ref_log or (want and name not in want):
            continue
        if not os.path.exists(os.path.join(DISCS, name + '.bin')):
            print('%-32s no disc' % name); continue
        got = run(name, RUN_S.get(name, 25))
        open(os.path.join(OUT, name + '.log'), 'w', encoding='latin-1').write(got)
        # DuckStation does not log a blank TTY line: blank lines are left out on both sides
        ref = os.path.join(OUT, name + '.ref')
        NL = chr(10)
        lines = open(ref_log, 'rb').read().decode('latin-1').replace(chr(13), '').split(NL)
        open(ref, 'w', encoding='latin-1').write(NL.join(l for l in lines if l.strip()))
        got = NL.join(l for l in got.split(NL) if l.strip())
        ok, line, a, b, ng, nr = ps1suite.text_compare(got, ref, ps1suite.NUM_TOL.get(name))
        print('%-32s %s' % (name, 'DS text OK (%d lines)' % nr if ok else
              'DS DIFFERS at line %d of %d (got %d): DS %r / console %r' % (line, nr, ng, a[:70], b[:70])), flush=True)

if __name__ == '__main__':
    main()
