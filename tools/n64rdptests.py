"""krom's RDP tests (github.com/PeterLemon/N64, RDP/) in the model, against the
screenshots of real hardware that come with them; and a game, for pictures.

    python tools/n64rdptests.py [FILTER ...] [--jobs N] [--tol T]
    python tools/n64rdptests.py --game ROM SECONDS[,SECONDS...] [PREFIX]

Each test ROM runs in tools/n64model.py (with tools/n64rdp.py drawing) until it
has plainly finished; the VI's framebuffer is written to build/n64rdp/NAME.png
and compared with krom's NAME.png.

The comparison: our framebuffer is read straight out of RDRAM as the VI's
registers describe it (5-bit channels widened as the VI does, v << 3 | v >> 2)
and, where the screenshot is a different size, sampled at the screenshot's
pixel centres. The screenshots are captures: some sit a line or two off the
framebuffer, so the best alignment within two pixels is taken (the table's
shift column). A pixel matches when no channel differs by more than --tol
(default 8, for the capture's noise and the VI's filters). The table gives the
share of pixels that match, and of those within 32. For the animated tests
(Rotate, Cube) the screenshot is one moment of the animation, so every frame
the model draws is compared and the best counts.

--game runs a ROM and writes the VI's picture at the given emulated seconds
(by the VI's frame count, 60 a second) to build/n64rdp/PREFIX_<frame>.png,
and PREFIX_latest.png every 30 frames to watch it go.
"""
import glob
import os
import struct
import sys
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import n64model  # noqa: E402
import n64rdp    # noqa: E402

ROOT = os.path.join(HERE, '..', 'sim', 'roms', 'n64', 'krom', 'RDP')
OUT = os.path.join(HERE, '..', 'build', 'n64rdp')


def read_png(path):
    """(w, h, rows of (r, g, b)) of an 8-bit RGB/RGBA/grey PNG, without PIL"""
    d = open(path, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n'
    p = 8
    idat = b''
    while p < len(d):
        n, tag = struct.unpack('>I4s', d[p:p + 8])
        body = d[p + 8:p + 8 + n]
        if tag == b'IHDR':
            w, h, bd, ct, _, _, il = struct.unpack('>IIBBBBB', body)
        elif tag == b'IDAT':
            idat += body
        p += 12 + n
    assert bd == 8 and il == 0, 'unsupported PNG'
    bpp = {0: 1, 2: 3, 4: 2, 6: 4}[ct]
    raw = zlib.decompress(idat)
    stride = w * bpp
    rows = []
    prev = bytearray(stride)
    i = 0
    for _ in range(h):
        ft = raw[i]
        cur = bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            a = cur[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if ft == 1: cur[x] = (cur[x] + a) & 0xFF
            elif ft == 2: cur[x] = (cur[x] + b) & 0xFF
            elif ft == 3: cur[x] = (cur[x] + ((a + b) >> 1)) & 0xFF
            elif ft == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                cur[x] = (cur[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 0xFF
        rows.append([tuple(cur[x * bpp:x * bpp + 3]) if bpp >= 3 else (cur[x * bpp],) * 3 for x in range(w)])
        prev = cur
    return w, h, rows


def vi_picture(m):
    """(w, h, rows of (r, g, b)) of the framebuffer the VI shows"""
    status, origin, width = m.vi[0], m.vi[1] & 0xFFFFFF, m.vi[2] & 0xFFF
    kind = status & 3
    if kind < 2 or not width:
        return 0, 0, []
    yscale = m.vi[13] & 0xFFF
    height = min(480, (yscale * 240) >> 10) if yscale else 240
    rd = m.rdram
    rows = []
    for y in range(height):
        row = []
        for x in range(width):
            if kind == 3:
                p = origin + 4 * (y * width + x)
                row.append((rd[p], rd[p + 1], rd[p + 2]))
            else:
                p = origin + 2 * (y * width + x)
                v = (rd[p] << 8) | rd[p + 1]
                c = [(v >> s) & 31 for s in (11, 6, 1)]
                row.append(tuple((k << 3) | (k >> 2) for k in c))
        rows.append(row)
    return width, height, rows


def save_picture(pic, path):
    if pic[0]:
        flat = b''.join(bytes(v for px in row for v in px) for row in pic[2])
        n64model.write_png(path, pic[0], pic[1], flat)


def compare(ours, ref, tol):
    """(share within tol, share within 32, (dx, dy)): our picture sampled at
    the reference's size, at the best alignment within two pixels"""
    import numpy as np
    w, h, a = ours
    rw, rh, b = ref
    if not w or not h:
        return 0.0, 0.0, (0, 0)
    ys = [min(h - 1, (y * h) // rh) for y in range(rh)]
    xs = [min(w - 1, (x * w) // rw) for x in range(rw)]
    A = np.array([[a[sy][sx] for sx in xs] for sy in ys], dtype=np.int32)
    B = np.array(b, dtype=np.int32)
    m = 2
    best = None
    for dy in range(-m, m + 1):
        for dx in range(-m, m + 1):
            d = np.abs(A[m:rh - m, m:rw - m] - B[m + dy:rh - m + dy, m + dx:rw - m + dx]).max(axis=2)
            r = (100.0 * (d <= tol).mean(), 100.0 * (d <= 32).mean(), (dx, dy))
            if best is None or r[0] > best[0] or (r[0] == best[0] and (dx, dy) == (0, 0)):
                best = r
    return best


def ensure_rdp(m):
    """the model with the RDP behind its DP registers (n64model does this itself
    once it has the hook)"""
    if getattr(m, 'rdp', None) is not None:
        return
    m.rdp = n64rdp.RDP(m)
    rr, rw = m.reg_read, m.reg_write

    def reg_read(a):
        if 0x04100000 <= a < 0x04100020:
            return m.rdp.reg_read((a >> 2) & 7)
        return rr(a)

    def reg_write(a, v):
        if 0x04100000 <= a < 0x04100020:
            m.rdp.reg_write((a >> 2) & 7, v)
            return
        rw(a, v)
    m.reg_read, m.reg_write = reg_read, reg_write
    m.rsp.dp_read = lambda i: m.rdp.reg_read(i)
    m.rsp.dp_write = lambda i, v: m.rdp.reg_write(i, v)


def run_until_done(m, steps, quiet_frames=12, each_frame=None):
    """Run until `steps`, or until neither the CPU nor the RDP has written
    anything for `quiet_frames` video frames (n64model.run's rule, with more
    patience: some tests wait several frames before they draw). each_frame,
    if given, is called after every frame in which the RDP did something."""
    c = m.cpu
    frame, quiet = m.vi_frames, 0
    mark = (m.rdram_writes, m.rdp.commands)
    i = 0
    while i < steps:
        for _ in range(256):
            c.step()
        i += 256
        if m.vi_frames != frame:
            frame = m.vi_frames
            now = (m.rdram_writes, m.rdp.commands)
            if each_frame is not None and now[1] != mark[1]:
                each_frame()
            if now[1] and m.joy.pads[0]:
                m.joy.pads[0] = 0                # (RDPModeInput: let go once it has drawn)
            quiet = quiet + 1 if now == mark else 0
            mark = now
            if quiet >= quiet_frames:
                break


def run_one(args):
    rom_path, tol = args
    name = os.path.splitext(os.path.basename(rom_path))[0]
    ref_path = os.path.splitext(rom_path)[0] + '.png'
    t0 = time.time()
    m = n64model.N64(open(rom_path, 'rb').read())
    ensure_rdp(m)
    m.fast_boot()
    ref = read_png(ref_path) if os.path.exists(ref_path) else None
    if 'RDPModeInput' in rom_path:
        # it draws only when a button moves its cursor: Up and Down together
        # move it there and back, so it draws its first screen
        m.joy.pads[0] = (1 << 27) | (1 << 26)
    animated = any(k in rom_path for k in ('Rotate', 'Cube'))
    best = [None, None]

    def each_frame():
        p = vi_picture(m)
        r = compare(p, ref, tol)
        if best[0] is None or r[0] > best[0][0]:
            best[0], best[1] = r, p
    try:
        run_until_done(m, 120_000_000 if animated else 40_000_000,
                       each_frame=each_frame if (animated and ref) else None)
        err = ''
    except Exception as e:                       # a crash in the model is a result too
        err = '%s: %s' % (type(e).__name__, e)
    pic = vi_picture(m)
    if best[1] is not None:
        each_frame()
        pic = best[1]
    save_picture(pic, os.path.join(OUT, name + '.png'))
    if ref is not None:
        good, near, shift = compare(pic, ref, tol)
        refsize = '%dx%d' % (ref[0], ref[1])
    else:
        good = near = 0.0
        shift = (0, 0)
        refsize = '-'
    rel = os.path.relpath(rom_path, ROOT).replace('\\', '/')
    return dict(name=name, rel=rel, good=good, near=near, size='%dx%d' % pic[:2], refsize=refsize,
                prims=m.rdp.prims, secs=time.time() - t0, err=err, shift=shift)


def run_game(rom_path, seconds, prefix, snap_every=0):
    """a game in the model: the VI's picture at each of `seconds` (emulated, by
    the VI's frame count) as build/n64rdp/PREFIX_<frame>.png"""
    rom = open(rom_path, 'rb').read()
    if rom[:4] == bytes((0x37, 0x80, 0x40, 0x12)):         # byte-swapped (.v64)
        rom = bytes(b for i in range(0, len(rom), 2) for b in (rom[i + 1], rom[i]))
    m = n64model.N64(rom)
    ensure_rdp(m)
    m.fast_boot()
    c = m.cpu
    t0 = time.time()
    targets = sorted(int(s * 60) for s in seconds)
    frame = m.vi_frames
    while targets:
        for _ in range(1024):
            c.step()
        if m.vi_frames == frame:
            continue
        frame = m.vi_frames
        if snap_every and frame % snap_every == 0:
            save_picture(vi_picture(m), os.path.join(OUT, '%s_latest.png' % prefix))
            print('frame %d (%.1f s emulated): %.0f s, %d instructions, %d RSP, RDP %d cmds %d prims %d pixels'
                  % (frame, frame / 60, time.time() - t0, c.instructions, m.rsp.instructions, m.rdp.commands,
                     m.rdp.prims, m.rdp.pixels), flush=True)
        if frame >= targets[0]:
            save_picture(vi_picture(m), os.path.join(OUT, '%s_%04d.png' % (prefix, frame)))
            print('wrote %s_%04d.png' % (prefix, frame), flush=True)
            targets.pop(0)


def main():
    os.makedirs(OUT, exist_ok=True)
    if '--game' in sys.argv:
        i = sys.argv.index('--game')
        secs = [float(v) for v in sys.argv[i + 2].split(',')]
        prefix = sys.argv[i + 3] if len(sys.argv) > i + 3 else 'game'
        run_game(sys.argv[i + 1], secs, prefix, snap_every=30)
        return
    argv = list(sys.argv[1:])
    jobs, tol = os.cpu_count(), 8
    if '--jobs' in argv:
        k = argv.index('--jobs')
        jobs = int(argv[k + 1])
        del argv[k:k + 2]
    if '--tol' in argv:
        k = argv.index('--tol')
        tol = int(argv[k + 1])
        del argv[k:k + 2]
    roms = sorted(glob.glob(os.path.join(ROOT, '**', '*.N64'), recursive=True))
    if argv:
        roms = [r for r in roms if any(a.lower() in r.replace(os.sep, '/').lower() for a in argv)]
    work = [(r, tol) for r in roms]
    if jobs > 1 and len(work) > 1:
        import multiprocessing
        with multiprocessing.Pool(jobs) as pool:
            results = pool.map(run_one, work, chunksize=1)
    else:
        results = [run_one(w) for w in work]
    print('%-60s %8s %8s %6s %9s %9s %6s %6s' % ('test', 'match%', '<=32%', 'shift', 'ours', 'shot', 'prims', 'secs'))
    for r in results:
        print('%-60s %8.2f %8.2f %6s %9s %9s %6d %6.1f %s' % (r['rel'][-60:], r['good'], r['near'],
                                                              '%+d%+d' % r['shift'], r['size'], r['refsize'],
                                                              r['prims'], r['secs'], r['err']))
    if results:
        print('mean match %.2f%% over %d tests; %d at >= 99%%, %d at >= 95%%'
              % (sum(r['good'] for r in results) / len(results), len(results),
                 sum(r['good'] >= 99 for r in results), sum(r['good'] >= 95 for r in results)))


if __name__ == '__main__':
    main()
