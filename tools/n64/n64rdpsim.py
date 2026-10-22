"""The RDP by itself: a window of a ROM's RDP work, captured from the model
(tools/n64/n64rdp.py) and replayed into rtl/n64_rdp.v by sim/tb_n64_rdp.v.

    python tools/n64/n64rdpsim.py ROM [--from F] [--frames N] [--input HEX]
        runs ROM in the model, drawing nothing until VI frame F (default 0), then
        captures N frames (default: until the program goes quiet) into sim/n64d/
    ./tools/sim.sh tb_n64_rdp
    python tools/n64/n64rdpsim.py --check [--png [--origin HEX]]
        compares the RDRAM the RTL left with the model's

What is captured:
  rdram.hex   all of RDRAM at the window's start, a 128-bit line per row (byte 0
              in bits 7:0, as the board's DDR3 holds it), with the preamble below
              written into its last 4 kB
  tmem.hex    TMEM at the start: 2048 16-bit words, tools/n64/n64rdp.py's indexing
  writes.hex  the DP register writes in order: "idx value" per row, the preamble's
              first
  after.bin   RDRAM at the window's end, as the model left it

The preamble puts the RDP into the state the model had at the window's start
with ordinary commands (SET_OTHER_MODES, SET_COMBINE, the colours, the tiles,
the images...), then leaves START/END/CURRENT as the model had them.

The model runs with its ninth (hidden) RDRAM bits held at 3, because the RTL has
none: on the board RDRAM is DDR3, eight bits a byte.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import n64model  # noqa: E402
import n64rdp    # noqa: E402

OUT = os.path.join(HERE, '..', '..', 'sim', 'n64d')
M32 = 0xFFFFFFFF


class TrackRam(bytearray):
    """RDRAM that notes which 16-byte lines are written, and by whom: the RDP
    (while it runs) or anything else (the CPU, the RSP's DMA, the PI)"""

    def __init__(self, data):
        super().__init__(data)
        self.rdp = False
        self.rdp_lines = set()
        self.other = set()

    def __setitem__(self, k, v):
        super().__setitem__(k, v)
        if isinstance(k, slice):
            a, b, _ = k.indices(len(self))
            lines = range(a >> 4, ((b - 1) >> 4) + 1) if b > a else ()
        else:
            lines = (k >> 4,)
        (self.rdp_lines if self.rdp else self.other).update(lines)


class ConstHidden:
    """RDRAM's ninth bits as the board has them: none. Every read is 3 (all
    set, as the model starts them), and writes are dropped."""

    def __init__(self, n):
        self.n = n

    def __len__(self):
        return self.n

    def __getitem__(self, k):
        if isinstance(k, slice):
            return bytes([3]) * len(range(*k.indices(self.n)))
        return 3

    def __setitem__(self, k, v):
        pass


def preamble(r):
    """64-bit commands that put a fresh RDP into r's state"""
    c = []

    def cmd(w0, w1):
        c.append(((w0 & M32) << 32) | (w1 & M32))
    cmd(r.om0 | (0x2F << 24), r.om1)
    c0, c1 = r.comb
    a = ((0x3C << 24) | (c0[0] << 20) | (c0[2] << 15) | (c0[4] << 12) | (c0[6] << 9) | (c1[0] << 5) | c1[2])
    b = ((c0[1] << 28) | (c1[1] << 24) | (c1[4] << 21) | (c1[6] << 18) | (c0[3] << 15) | (c0[5] << 12)
         | (c0[7] << 9) | (c1[3] << 6) | (c1[5] << 3) | c1[7])
    cmd(a, b)
    cmd(0x37 << 24, r.fill_color)
    cmd(0x38 << 24, r.fog_color)
    cmd(0x39 << 24, r.blend_color)
    cmd((0x3A << 24) | (r.prim_min_level << 8) | r.prim_lod_frac, r.prim_color)
    cmd(0x3B << 24, r.env_color)
    cmd((0x2A << 24) | (r.key_width[1] << 12) | r.key_width[2],
        (r.key_center[1] << 24) | (r.key_scale[1] << 16) | (r.key_center[2] << 8) | r.key_scale[2])
    cmd(0x2B << 24, (r.key_width[0] << 16) | (r.key_center[0] << 8) | r.key_scale[0])
    k = [((v - 1) >> 1) & 0x1FF for v in r.convert[:4]] + [r.convert[4] & 0x1FF, r.convert[5] & 0x1FF]
    m = 0
    for v in k:
        m = (m << 9) | v
    cmd((0x2C << 24) | (m >> 32), m & M32)
    sc = r.scissor
    cmd((0x2D << 24) | (sc[0] << 12) | sc[1], (r.scissor_field << 25) | (r.scissor_odd << 24) | (sc[2] << 12) | sc[3])
    cmd(0x2E << 24, (((r.prim_depth >> 16) & 0x7FFF) << 16) | (r.prim_dz & 0xFFFF))
    for i, t in enumerate(r.tiles):
        f = t.flags
        cmd((0x35 << 24) | (t.fmt << 21) | (t.size << 19) | ((t.stride >> 3) << 9) | (t.offset >> 3),
            (i << 24) | (t.palette << 20) | ((1 if f & n64rdp.TILE_CLAMP_T else 0) << 19)
            | ((1 if f & n64rdp.TILE_MIRROR_T else 0) << 18) | (t.mask_t << 14) | (t.shift_t << 10)
            | ((1 if f & n64rdp.TILE_CLAMP_S else 0) << 9) | ((1 if f & n64rdp.TILE_MIRROR_S else 0) << 8)
            | (t.mask_s << 4) | t.shift_s)
        cmd((0x32 << 24) | (t.slo << 12) | t.tlo, (i << 24) | (t.shi << 12) | t.thi)
    addr, width, fmt, size = r.timg
    cmd((0x3D << 24) | (fmt << 21) | (size << 19) | ((width - 1) & 0x3FF), addr)
    cmd(0x3E << 24, r.z_addr)
    if r.fb_width:
        fsize = {n64rdp.FB_I4: 0, n64rdp.FB_I8: 1, n64rdp.FB_RGBA5551: 2, n64rdp.FB_IA88: 2, n64rdp.FB_RGBA8888: 3}[r.fb_fmt]
        ffmt = 3 if r.fb_fmt == n64rdp.FB_IA88 else 0
        cmd((0x3F << 24) | (ffmt << 21) | (fsize << 19) | ((r.fb_width - 1) & 0x3FF), r.fb_addr)
    return c


def run_frames(m, until_frame, quiet_frames=12, max_steps=400_000_000):
    """step the machine to VI frame until_frame (None: until it goes quiet)"""
    c = m.cpu
    frame, quiet = m.vi_frames, 0
    mark = (m.rdram_writes, m.rdp.commands)
    for i in range(0, max_steps, 256):
        for _ in range(256):
            c.step()
        if m.vi_frames != frame:
            frame = m.vi_frames
            for f, v in PRESS:
                if frame == f:
                    m.joy.pads[0] = v           # (--press: a controller schedule)
            if until_frame is not None and frame >= until_frame:
                return
            now = (m.rdram_writes, m.rdp.commands)
            quiet = quiet + 1 if now == mark else 0
            mark = now
            if until_frame is None and quiet >= quiet_frames:
                return


PRESS = []                                  # [(VI frame, pad bits)]


def capture(rom_path, start, nframes, pads, snap=None):
    os.makedirs(OUT, exist_ok=True)
    if snap:
        # a machine pickled by tools/n64/n64rdpcensus.py (--snap-*), carried on from
        import pickle
        import __main__
        import n64rdpcensus
        __main__.Census = n64rdpcensus.Census
        m = pickle.load(open(snap, 'rb'))[0]
        m.rdp.draw = True
    else:
        m = n64model.N64(open(rom_path, 'rb').read())
        m.fast_boot()
    if pads is not None:
        m.joy.pads[0] = pads
    r = m.rdp
    if start:
        r.draw = False
        run_frames(m, start)
        # (a command cut in two by END would be half in the model's hand: wait for none)
        while r.pending:
            m.cpu.step()
    r.hidden = ConstHidden(len(m.rdram) >> 1)
    r.draw = True
    # (the primitives' count, the noise's seed, from 0 as the RTL's starts: no command sets it)
    r.prims = 0
    # the preamble, at the top of RDRAM
    pre = preamble(r)
    base = len(m.rdram) - 4096
    assert len(pre) * 8 <= 4096
    rd0 = bytearray(m.rdram)
    for i, w in enumerate(pre):
        rd0[base + 8 * i:base + 8 * i + 8] = w.to_bytes(8, 'big')
    writes = [(3, 1 | 4 | 16), (0, base), (1, base + 8 * len(pre))]     # (RDRAM, not frozen, not flushed)
    writes += [(0, r.current), (1, r.current)]                          # the walk where the model's is
    if r.start_valid:
        writes.append((0, r.start))
    if r.end != r.current:
        writes.append((1, r.end))
    if r.source:
        writes.append((3, 2))
    tm0 = list(r.tmem)
    # RDRAM that knows who wrote it: what else writes between the RDP's register
    # writes goes into the list too, as lines to load before the write
    ram = TrackRam(m.rdram)
    m.rdram = ram
    orig = r.reg_write
    orig_run = r.run

    def rw(i, v):
        for line in sorted(ram.other):
            writes.append(('L', line, bytes(ram[16 * line:16 * line + 16])))
        ram.other.clear()
        writes.append((i & 7, v & M32))
        ram.rdp = True
        try:
            orig(i, v)
        finally:
            ram.rdp = False

    def run(mm=None):
        was, ram.rdp = ram.rdp, True
        try:
            orig_run(mm)
        finally:
            ram.rdp = was
    r.reg_write = rw
    r.run = run
    sources = [r.source]
    run_frames(m, None if nframes is None else m.vi_frames + nframes)
    r.reg_write = orig
    r.run = orig_run
    if r.source or any(sources):
        print('note: the RDP read commands over the XBUS (DMEM): the bench has no DMEM')
    if r.fb_fmt == n64rdp.FB_I4:
        print('note: a 4-bit colour image keeps alpha in the ninth bits, which the board has not got')
    with open(os.path.join(OUT, 'rdram.hex'), 'w') as f:
        for a in range(0, len(rd0), 16):
            f.write(rd0[a:a + 16][::-1].hex() + '\n')
    with open(os.path.join(OUT, 'tmem.hex'), 'w') as f:
        for v in tm0:
            f.write('%04x\n' % (v & 0xFFFF))
    with open(os.path.join(OUT, 'writes.hex'), 'w') as f:
        # "0 idx value": a DP register write; "1 line data": a line of RDRAM to load
        # first (written by the CPU or the RSP since the last register write)
        f.write('%x\n' % len(writes))
        for w in writes:
            if w[0] == 'L':
                f.write('1 %05x %s\n' % (w[1], w[2][::-1].hex()))
            else:
                f.write('0 %x %08x\n' % (w[0], w[1]))
    with open(os.path.join(OUT, 'rdp_lines.txt'), 'w') as f:
        f.write(' '.join('%x' % l for l in sorted(ram.rdp_lines)))
    open(os.path.join(OUT, 'after.bin'), 'wb').write(bytes(m.rdram))
    open(os.path.join(OUT, 'vi.txt'), 'w').write('%x %x %x\n' % (m.vi[0], m.vi[1], m.vi[2]))
    changed = sum(1 for a in range(0, len(rd0), 16) if rd0[a:a + 16] != m.rdram[a:a + 16])
    print('%d DP register writes, %d commands, %d pixels; %d RDRAM lines changed'
          % (len(writes), r.commands, r.pixels, changed))


def check(png):
    rd0 = bytearray()
    for l in open(os.path.join(OUT, 'rdram.hex')):
        rd0 += bytes.fromhex(l.strip())[::-1]
    exp = open(os.path.join(OUT, 'after.bin'), 'rb').read()
    got = bytearray(rd0)
    p = os.path.join(OUT, 'rtl_lines.hex')
    if os.path.exists(p):
        for l in open(p):
            a, d = l.split()
            a = int(a, 16) * 16
            got[a:a + 16] = bytes.fromhex(d)[::-1]
    else:
        print('no rtl_lines.hex: did the bench run?')
    base = len(rd0) - 4096
    # the lines the RDP wrote, in the model or in the RTL (what else changed RDRAM
    # is not the RDP's to match)
    p = os.path.join(OUT, 'rdp_lines.txt')
    lines = {int(x, 16) for x in open(p).read().split()} if os.path.exists(p) else set(range(base >> 4))
    p = os.path.join(OUT, 'rtl_lines.hex')
    if os.path.exists(p):
        lines |= {int(l.split()[0], 16) for l in open(p)}
    bad = [16 * l for l in sorted(lines) if 16 * l < base and got[16 * l:16 * l + 16] != exp[16 * l:16 * l + 16]]
    model_lines = sum(1 for l in lines if 16 * l < base and rd0[16 * l:16 * l + 16] != exp[16 * l:16 * l + 16])
    if bad:
        print('RDRAM: %d of the model\'s %d changed lines differ; first at %06x:' % (len(bad), model_lines, bad[0]))
        for a in bad[:6]:
            print('   %06x model %s  rtl %s  before %s' % (a, exp[a:a + 16].hex(), got[a:a + 16].hex(), rd0[a:a + 16].hex()))
    else:
        print('RDRAM: the same (%d lines changed by both)' % model_lines)
    if png:
        st, origin, width = [int(x, 16) for x in open(os.path.join(OUT, 'vi.txt')).read().split()]
        if '--origin' in sys.argv:           # another buffer than the one the VI showed
            origin = int(sys.argv[sys.argv.index('--origin') + 1], 16)
        for name, mem in (('model', exp), ('rtl', got)):
            m = n64model.N64(b'\0' * 0x1000)
            m.rdram[:] = mem[:len(m.rdram)]
            m.vi[0], m.vi[1], m.vi[2] = st, origin, width
            w, h, rgb = m.framebuffer()
            path = os.path.join(OUT, '%s.png' % name)
            n64model.write_png(path, w, h, rgb)
            print('%s picture -> %s' % (name, path))
    return not bad


if __name__ == '__main__':
    if '--check' in sys.argv:
        sys.exit(0 if check('--png' in sys.argv) else 1)
    arg = lambda k, d: int(sys.argv[sys.argv.index(k) + 1], 0) if k in sys.argv else d
    if '--press' in sys.argv:
        # "frame:value,frame:value": the pad from that VI frame on
        for item in sys.argv[sys.argv.index('--press') + 1].split(','):
            f, v = item.split(':')
            PRESS.append((int(f, 0), int(v, 0)))
    snap = sys.argv[sys.argv.index('--snap') + 1] if '--snap' in sys.argv else None
    capture(sys.argv[1], arg('--from', 0), arg('--frames', None), arg('--input', None), snap)
