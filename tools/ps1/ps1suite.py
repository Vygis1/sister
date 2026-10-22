"""ps1suite.py - JaCzekanski's ps1-tests run on the board and checked against the real console's
results: the text each prints (psx.log) and, for the GPU tests, video memory (vram.png).

    python tools/ps1/ps1suite.py [NAME ...]        (default: every test with a reference)

Needs a debug build in the FPGA (core.sh PS1_DBG=1 JTAG=1: the TTY ring, the raw frame window and
the register bus over JTAG -- tools/jtag.py) with the BIOS loaded (any PlayStation game started from
the menu once), the tests on the card as /roms/ps1tests/NAME.bin (tools/ps1/exedisc.py), and
tools/pad.py running: the ESP32 is the disc drive, so it is told which disc is in; everything else
goes over JTAG.

Each test: its disc in, the console reset, its output followed until it stops changing; then
compared. Results to build/ps1suite/: NAME.log (what it printed), NAME_vram.png, and a summary.
"""
import os
import socket
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..', '..')
sys.path.insert(0, os.path.join(ROOT, 'tools'))
from jtag import Jtag  # noqa: E402

TESTS = os.path.join(ROOT, 'build', 'ps1tests')
OUT = os.path.join(ROOT, 'build', 'ps1suite')
CTRL = 0x80000
FB = 0x100000
PACE = int(os.environ.get('PS1_PACE', '0x19000'), 0)     # ctrl 0xEC: 12 the console's pace, 15 the long lead, 16 DMA charged
# interactive (a pad, a disc swap) or open-ended: not run unattended
SKIP = {'input_pad', 'cdrom_disc-swap', 'cdrom_terminal', 'spu_toolbox', 'spu_ram-sandbox', 'gpu_benchmark',
        'mdec_step-by-step-log', 'gte-fuzz',
        # a movie playing: its reference is one moment of it, ours is another (checked by eye:
        # the frames decode clean)
        'mdec_movie_movie-15bit', 'mdec_movie_movie-24bit',
        # the CPU-read 24-bit frame: the test does not put the MDEC's 8x8 blocks in rows
        # ("swizzling for 24bit not implemented"), so no console's picture matches its reference
        'mdec_frame_frame-24bit',
        # needs a MODIFIED console: CPU pin 160 (TCLK0) cut from the GPU and wired to the serial
        # port's RTS, so the program can clock Timer0 by hand; the reference log is from one
        'timer-dump'}


def tests():
    out = []
    for d, _, files in os.walk(TESTS):
        for fn in files:
            if fn.lower().endswith('.exe') and 'tools' not in os.path.relpath(d, TESTS).replace('\\', '/').split('/'):
                rel = os.path.relpath(os.path.join(d, fn), TESTS).replace('\\', '/')
                parts = rel.rsplit('.', 1)[0].split('/')
                if len(parts) >= 2 and parts[-1] == parts[-2]:
                    parts = parts[:-1]
                name = '_'.join(parts)
                ref_log = os.path.join(d, 'psx.log')
                ref_vram = [os.path.join(d, f) for f in os.listdir(d) if f.startswith('vram') and f.endswith('.png')]
                out.append((name, ref_log if os.path.exists(ref_log) else None, ref_vram))
    return sorted(out)


def exe_range(name):
    """where the test's EXE loads (its header), as physical addresses"""
    import struct
    for d, _, files in os.walk(TESTS):
        for fn in files:
            if fn.lower().endswith('.exe'):
                rel = os.path.relpath(os.path.join(d, fn), TESTS).replace('\\', '/').rsplit('.', 1)[0].split('/')
                if len(rel) >= 2 and rel[-1] == rel[-2]:
                    rel = rel[:-1]
                if '_'.join(rel) == name:
                    h = open(os.path.join(d, fn), 'rb').read(0x20)
                    ta, ts = struct.unpack('<II', h[0x18:0x20])
                    return ta & 0x1FFFFFFF, (ta & 0x1FFFFFFF) + ts
    return 0x10000, 0x200000


class Pad:
    """tools/pad.py's port: only to tell the ESP32 (the disc drive) which disc is in"""
    def __init__(self):
        self.f = socket.create_connection(('127.0.0.1', 5557), timeout=10).makefile('rwb')

    def serial(self, line):
        self.f.write(b'S ' + line.encode() + b'\n'); self.f.flush(); self.f.readline()


def tty_read(j, start, count):
    """the characters printed from count `start` to `count` (the ring keeps the last 16 kB;
    the counter runs on across console resets, so a test's text starts where it stood before)"""
    words = j.read_block(CTRL + 0x8000, 4096)
    ring = b''.join(w.to_bytes(4, 'little') for w in words)
    n = min(count - start, 16384)
    return bytes(ring[(count - n + i) % 16384] for i in range(n))


UNTIL = {'gpu_bandwidth': b'Done'}


def run_one(j, pad, name, max_s=90, quiet_s=6, text=True):
    pad.serial('disc /roms/ps1tests/%s.bin' % name)
    time.sleep(1.0)
    j.write(CTRL + 0xEC, PACE)                           # the CPU at the console's pace (bit 12)
    j.write(CTRL + 0x04, 0); time.sleep(0.2)
    start = j.read(CTRL + 0x1A8)
    j.write(CTRL + 0x04, 1)
    if not text:                                         # a picture test: once it runs, let it draw
        lo, hi = exe_range(name)
        t0 = time.time()
        while time.time() - t0 < 40:
            time.sleep(0.5)
            if lo <= (j.read(CTRL + 0x14) & 0x1FFFFFFF) < hi:
                break
        time.sleep(3)
        return ''
    # (a test that measures for seconds between lines -- gpu/bandwidth -- is waited for to
    # its last line, not to the first quiet spell)
    until = UNTIL.get(name)
    t0 = time.time(); last = -1; last_t = t0
    while time.time() - t0 < (180 if until else max_s):
        time.sleep(1.0)
        n = j.read(CTRL + 0x1A8)
        if until:
            if n > start and until in tty_read(j, max(start, n - 64), n):
                break
            continue
        if n != last:
            last, last_t = n, time.time()
        elif time.time() - last_t > quiet_s and n > start:
            break
    n = j.read(CTRL + 0x1A8)
    return tty_read(j, start, n).decode('latin-1')


def vsync_range(name):
    """the test's VSync(): the code that reads timer 1 (lw ..., 0x1110(...)) -- where the
    program waits with its frame drawn"""
    import struct
    lo, hi = exe_range(name)
    for d, _, files in os.walk(TESTS):
        for fn in files:
            if fn.lower().endswith('.exe'):
                rel = os.path.relpath(os.path.join(d, fn), TESTS).replace(os.sep, '/').rsplit('.', 1)[0].split('/')
                if len(rel) >= 2 and rel[-1] == rel[-2]:
                    rel = rel[:-1]
                if '_'.join(rel) == name:
                    b = open(os.path.join(d, fn), 'rb').read()[0x800:]
                    hits = [lo + i for i in range(0, len(b) - 3, 4)
                            if (struct.unpack('<I', b[i:i + 4])[0] >> 26) == 0x23 and struct.unpack('<I', b[i:i + 4])[0] & 0xFFFF == 0x1110]
                    if hits:
                        return min(hits) - 0x10, max(hits) + 0x40
    return None


def halt_at_vsync(j, name, tries=400):
    """halt the processor (ctrl bit 2) while the test waits for vertical sync: its frame is
    complete then. Most tests redraw every frame; halted anywhere else, the dump catches the
    frame part drawn."""
    r = vsync_range(name) if name else None
    for _ in range(tries if r else 1):
        pc = j.read(CTRL + 0x14) & 0x1FFFFFFF
        if r is None or r[0] <= pc < r[1]:
            j.write(CTRL + 0x04, 1 | 4)
            pc = j.read(CTRL + 0x14) & 0x1FFFFFFF
            if r is None or r[0] <= pc < r[1]:
                return True
            j.write(CTRL + 0x04, 1)
    j.write(CTRL + 0x04, 1 | 4)
    return False


def halt_late_in_frame(j, ms=13):
    """halt `ms` after a vertical blank (ctrl 0x4C counts them). Where a test's frame is whole
    differs: gpu/lines is whole 1-8 ms after the blank and redrawing by 12 -- so the looks
    are taken at several points and the closest kept"""
    v0 = j.read(CTRL + 0x4C) & 0xFFFF
    t0 = time.time()
    while (j.read(CTRL + 0x4C) & 0xFFFF) == v0 and time.time() - t0 < 1:
        pass
    time.sleep(ms / 1000.0)
    j.write(CTRL + 0x04, 1 | 4)


def vram_dump(j, name=None, ms=13):
    halt_late_in_frame(j, ms); time.sleep(0.3)
    j.write(CTRL + 0xE0, 1)
    for _ in range(200):
        if not j.read(CTRL + 0xE0) >> 31:
            break
    px = []
    for base in (0x0000, 0x8000):                       # two halves of 512 kB through the 640 kB window
        j.write(CTRL + 0x1AC, 0x80000000 | base)
        px += j.read_block(FB, 0x20000)
    j.write(CTRL + 0x1AC, 0)
    halves = []
    for w in px:
        halves += [w & 0xFFFF, w >> 16]
    return halves                                        # 1024 x 512, row-major


# where a test's reference picture was made with an older build whose background differs from
# what this binary clears to (gpu/transparency: the old library cleared to white, this one to
# black), only the area the test draws is compared
VRAM_BOX = {'gpu_transparency': (0, 0, 320, 240)}


def vram_compare(halves, ref_png, out_png, box=None):
    from PIL import Image
    ref = Image.open(ref_png).convert('RGB')
    w, h = ref.size
    img = Image.new('RGB', (1024, 512))
    bad = 0; first = None
    rp = ref.load(); ip = img.load()
    for y in range(512):
        for x in range(1024):
            p = halves[y * 1024 + x]
            c = ((p & 31) << 3, ((p >> 5) & 31) << 3, ((p >> 10) & 31) << 3)
            ip[x, y] = c
            if x < w and y < h and (box is None or (box[0] <= x < box[2] and box[1] <= y < box[3])):
                r = rp[x, y]
                if (r[0] & 0xF8, r[1] & 0xF8, r[2] & 0xF8) != c:
                    bad += 1
                    if first is None:
                        first = (x, y, c, r)
    img.save(out_png)
    return bad, first


# tests that only PRINT measurements -- the console's own runs differ from one another -- are
# compared as text with every number allowed this far (relative) from the console's
NUM_TOL = {'cpu_access-time': 0.15, 'timers': 0.03, 'dma_chain-looping': 0.20, 'gpu_bandwidth': 0.20,
           'dma_chopping': 0.30, 'cdrom_timing': 0.60}


def _line_eq(a, b, tol):
    import re
    if a == b:
        return True
    if tol is None:
        return False
    na = re.split(r'(-?\d+(?:\.\d+)?)', a); nb = re.split(r'(-?\d+(?:\.\d+)?)', b)
    if len(na) != len(nb):
        return False
    for i, (x, y) in enumerate(zip(na, nb)):
        if i % 2 == 0:
            if x.split() != y.split():
                return False
        else:
            fx, fy = float(x), float(y)
            if abs(fx - fy) > max(1.0, tol * abs(fy)):
                return False
    return True


def text_compare(got, ref_path, tol=None):
    ref = open(ref_path, 'rb').read().decode('latin-1')
    g = [l.rstrip() for l in got.replace('\r', '').split('\n')]
    r = [l.rstrip() for l in ref.replace('\r', '').split('\n')]
    if r and r[0].startswith('% '):
        r = [l[2:] if l.startswith('% ') else ('' if l == '%' else l) for l in r]   # some logs prefix every line with '% '
    ign = ('ResetGraph:', 'VSync: timeout')                   # build addresses / our own retries
    r = [l for l in r if not l.startswith(ign)]
    g = [l for l in g if not l.startswith(ign)]
    while g and not g[-1]: g.pop()
    while r and not r[-1]: r.pop()
    # our capture starts at power-on and has the BIOS's own messages first; the console's
    # log starts with the test's first line
    while r and not r[0]: r.pop(0)
    if r and r[0] in g:
        g = g[g.index(r[0]):]
    # a pass/fail test: every subtest the console passed must pass here, and none may fail
    # (the console's log can predate subtests the program now has)
    if any(l.startswith('pass - ') for l in r):
        fails = [l for l in g if l.startswith('fail - ')]
        if fails:
            return False, g.index(fails[0]) + 1, fails[0], '(no failures)', len(g), len(r)
        for i, l in enumerate(r):
            if l.startswith('pass - ') and l not in g:
                return False, i + 1, '<missing>', l, len(g), len(r)
        return True, 0, '', '', len(g), len(r)
    # the console's lines, in order; ours may have more (these test builds are newer than some
    # of the logs, and print an extra total or a newer subtest)
    j = 0
    for i, b in enumerate(r):
        k = j
        while k < len(g) and not _line_eq(g[k], b, tol):
            k += 1
        if k == len(g):
            return False, i + 1, g[j] if j < len(g) else '<nothing>', b, len(g), len(r)
        j = k + 1
    return True, 0, '', '', len(g), len(r)


def recheck():
    """compare the logs already in build/ps1suite with the console's, without running anything"""
    for name, ref_log, ref_vram in tests():
        f = os.path.join(OUT, name + '.log')
        if ref_log and os.path.exists(f):
            got = open(f, encoding='latin-1').read()
            ok, line, a, b, ng, nr = text_compare(got, ref_log, NUM_TOL.get(name))
            print('%-32s %s' % (name, 'text OK (%d lines)' % nr if ok else
                  'text DIFFERS at line %d of %d (got %d): ours %r / console %r' % (line, nr, ng, a[:80], b[:80])))


def main():
    if sys.argv[1:] == ['recheck']:
        return recheck()
    want = set(sys.argv[1:])
    os.makedirs(OUT, exist_ok=True)
    j = Jtag(); pad = Pad()
    summary = []
    for name, ref_log, ref_vram in tests():
        if want and name not in want:
            continue
        if not want and (name in SKIP or (not ref_log and not ref_vram)):
            continue
        print('--- %s' % name, flush=True)
        got = run_one(j, pad, name, text=bool(ref_log))
        open(os.path.join(OUT, name + '.log'), 'w', encoding='latin-1').write(got)
        res = []
        if ref_log:
            ok, line, a, b, ng, nr = text_compare(got, ref_log, NUM_TOL.get(name))
            res.append('text OK (%d lines)' % nr if ok else
                       'text DIFFERS at line %d of %d (got %d): ours %r / console %r' % (line, nr, ng, a[:90], b[:90]))
        # (the MDEC tests keep a 15-bit and a 24-bit reference: the one for this test's depth)
        depth = '24bit' if '24bit' in name else '15bit' if '15bit' in name else ''
        pick = [r for r in ref_vram if depth and depth in os.path.basename(r)] or ref_vram
        for rv in pick[:1]:
            # up to three looks, at three frames, the closest kept: a test that redraws every frame
            # is caught part way through its frame now and then (the CPU runs at the console's
            # pace, and a long frame can outlast the halt's guess); a real fault shows in all three
            best = None
            for look, ms in enumerate((13, 3, 8)):
                bad, first = vram_compare(vram_dump(j, name, ms), rv, os.path.join(OUT, name + '_vram%d.png' % look), VRAM_BOX.get(name))
                if best is None or bad < best[0]:
                    best = (bad, first, look)
                j.write(CTRL + 0x04, 1)                       # let it run on to another frame
                if bad == 0:
                    break
                time.sleep(0.4)
            bad, first, look = best
            os.replace(os.path.join(OUT, name + '_vram%d.png' % look), os.path.join(OUT, name + '_vram.png'))
            res.append('vram OK' if bad == 0 else 'vram DIFFERS: %d pixels, first at %s' % (bad, first))
        line = '%-32s %s' % (name, ' | '.join(res))
        print(line, flush=True)
        summary.append(line)
    open(os.path.join(OUT, 'summary.txt'), 'w').write('\n'.join(summary) + '\n')
    j.close()


if __name__ == '__main__':
    main()
