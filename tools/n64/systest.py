"""systest.py - n64-systemtest on the board, its text read back, judged against ares.

    python tools/n64/systest.py [--start] [--secs N]

The test ROM (lemmy-64/n64-systemtest, MIT; build/n64-systemtest, `cargo run --release` with
nust64) prints through the ISViewer: n64_top keeps that text in a 2 kB ring (n64_top isv_*),
read here through the debug window (console 0x170 select, 0x174 data) with tools/pad.py's register
pass-through (tool port 5557, "R addr" / "W addr value"). Saying how far the text has been read
turns on flow control in the core: the program waits for us rather than overwrite the ring.

--start  load it first through the menu (tools/menunav.py play "Nintendo 64" n64-systemtest).
The reference is ares' run of the same ROM: build/n64systest/ares.txt (ares --system "Nintendo 64"
ROM, stdout); ares fails 2 of 3721. Ours goes to build/n64systest/board.txt.
"""
import os, re, socket, subprocess, sys, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
OUT = os.path.join(ROOT, 'build', 'n64systest')
SEL, DATA = 0x80170, 0x80174
RING = 2048

class Bus:
    def __init__(self):
        self.f = socket.create_connection(('127.0.0.1', 5557), timeout=10).makefile('rwb')
    def _q(self, line):
        self.f.write((line + '\n').encode()); self.f.flush()
        return self.f.readline().decode().strip()
    def w(self, a, v): return self._q('W %x %x' % (a, v))
    def r(self, a):
        ans = self._q('R %x' % a)
        try:
            return int(ans, 16)
        except ValueError:
            raise IOError('register read: %r' % ans)

def fails(text):
    return [l for l in text.splitlines() if re.match(r"Test '.*' failed", l)]

def main():
    secs = 120
    if '--secs' in sys.argv:
        secs = int(sys.argv[sys.argv.index('--secs') + 1])
    os.makedirs(OUT, exist_ok=True)
    b = Bus()
    rp = None
    if '--start' in sys.argv:
        # the read position first: the ring then holds the program from its first line
        b.w(SEL, (3 << 30) | 0)
        wp0 = b.r(DATA) & 0x3FFFFF
        subprocess.run([sys.executable, os.path.join(ROOT, 'tools', 'menunav.py'), 'play', 'Nintendo 64', 'n64-systemtest'], check=True)
    b.w(SEL, (3 << 30))
    wp = b.r(DATA) & 0x3FFFFF
    rp = max(0, wp - RING) if rp is None else rp
    text = bytearray()
    t0 = last = time.time()
    while time.time() - t0 < secs:
        b.w(SEL, (3 << 30) | (rp << 8))                 # (how far we have read: flow control on)
        wp = b.r(DATA) & 0x3FFFFF
        if wp - rp > RING:
            print('!! %d bytes lost (the ring went round before flow control was on)' % (wp - rp - RING))
            rp = wp - RING
        while rp < wp:
            row = (rp >> 2) & (RING // 4 - 1)
            b.w(SEL, (2 << 30) | (row << 8))
            v = b.r(DATA)
            for k in range(rp & 3, 4):
                if rp >= wp: break
                text.append((v >> (24 - 8 * k)) & 0xFF); rp += 1
            if (rp & 0xFF) == 0:
                b.w(SEL, (3 << 30) | (rp << 8))
        if wp != 0 and time.time() - last > 2:
            last = time.time()
            sys.stdout.write('\r%d bytes' % len(text)); sys.stdout.flush()
        if b'Finished in' in text and b'Slowest tests' in text:
            break
        time.sleep(0.2)
    print()
    t = text.decode('latin-1')
    open(os.path.join(OUT, 'board.txt'), 'w', encoding='latin-1').write(t)
    m = re.search(r'Failed (\d+) of (\d+) tests', t)
    print('board: %s' % (m.group(0) if m else 'no summary line (%d bytes of text)' % len(t)))
    ref = os.path.join(OUT, 'ares.txt')
    if os.path.exists(ref):
        a = open(ref, encoding='latin-1').read()
        ma = re.search(r'Failed (\d+) of (\d+) tests', a)
        print('ares:  %s' % (ma.group(0) if ma else '?'))
        names = lambda L: {re.match(r"Test '(.*?)' failed", l).group(1) for l in L}
        ours, theirs = names(fails(t)), names(fails(a))
        print('failing on the board and not in ares (%d):' % len(ours - theirs))
        for n in sorted(ours - theirs):
            print('  ' + n)
        for l in fails(t):
            if re.match(r"Test '(.*?)' failed", l).group(1) in (ours - theirs):
                print('    ' + l[:220])

if __name__ == '__main__':
    main()
