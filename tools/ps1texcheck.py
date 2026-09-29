"""A texture test the board runs by itself, and the check of what it drew.

The program uploads a 64x64 fifteen-bit texture in which every texel states its
own coordinates -- red = u, green = v, blue = a checksum -- then draws it over
the screen with a textured quad, for ever. Every pixel of the picture that
comes back can therefore be traced to the texel it was fetched from, so a wrong
pixel says exactly WHICH texel the engine read instead of the right one. That
turns "the textures look like noise" into a number.

    python tools/ps1texcheck.py build      write sim/roms/ps1/texcheck.bin
    python tools/ps1texcheck.py run        load it on the board and check
"""
import os, sys, time, urllib.request
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE); sys.path.insert(0, os.path.join(HERE, "..", "pc"))
from mipsasm import *

GP0, GP1 = 0x1F801810, 0x1F801814
TEX_X, TEX_Y = 512, 0          # the texture page: VRAM (512, 0), page x = 8
TW, TH = 64, 64
SCR_W, SCR_H = 256, 224

def texel(u, v):
    """Fifteen bits that name their own texel: red = u[4:0], green = v[4:0],
    blue = {u[5], v[5], 001}. The 001 is a marker -- a pixel without it did not
    come from this texture at all -- and it also keeps the texel non-zero,
    which on this chip means "not transparent"."""
    return (((u >> 5) & 1) << 14) | (((v >> 5) & 1) << 13) | (1 << 10) | ((v & 31) << 5) | (u & 31)

def decode(p):
    """(u, v) of the texel a pixel came from, or None if it is not one of ours."""
    if ((p >> 10) & 7) != 1:
        return None
    return ((p & 31) | (((p >> 14) & 1) << 5), ((p >> 5) & 31) | (((p >> 13) & 1) << 5))

PAL_X, PAL_Y = 0, 500          # the palette: 16 entries at VRAM (0,500)

def pal_colour(i):
    """A palette entry that names its own index: red = green = i, blue = 1."""
    return (1 << 10) | ((i & 31) << 5) | (i & 31)

def index4(u, v):
    return (u + v) & 15

def build4():
    """The same test with a FOUR-BIT texture and a palette -- which is what a
    game's art actually uses, and the path the fifteen-bit test cannot reach."""
    a = Asm(org=0xBFC00000)
    a.li(T0, GP0); a.li(T1, GP1)
    def gp1(w): a.li(T2, w); a.sw(T2, 0, T1)
    def gp0(w): a.li(T2, w); a.sw(T2, 0, T0)
    gp1(0x0000_0000); gp1(0x0300_0000); gp1(0x0500_0000)
    gp1(0x0603_C060); gp1(0x0704_0010); gp1(0x0800_0001)
    gp0(0xE100_0008)                      # page x=8, y=0, FOUR-bit (bits 8:7 = 0)
    gp0(0xE300_0000)
    gp0(0xE400_0000 | ((SCR_H - 1) << 10) | (SCR_W - 1))
    gp0(0xE500_0000); gp0(0xE600_0000)
    # the palette: 16 halfwords at (0,500)
    gp0(0xA000_0000); gp0((PAL_Y << 16) | PAL_X); gp0((1 << 16) | 16)
    for i in range(0, 16, 2):
        gp0((pal_colour(i + 1) << 16) | pal_colour(i))
    # the texture: 64x64 four-bit texels = 16 halfwords a row, at (512,0)
    gp0(0xA000_0000); gp0((TEX_Y << 16) | TEX_X); gp0((TH << 16) | 16)
    for v in range(TH):
        row = []
        for u in range(0, TW, 4):
            hw = (index4(u, v) | (index4(u + 1, v) << 4)
                  | (index4(u + 2, v) << 8) | (index4(u + 3, v) << 12))
            row.append(hw)
        for k in range(0, len(row), 2):
            gp0((row[k + 1] << 16) | row[k])
    clut = ((PAL_Y & 511) << 6) | ((PAL_X >> 4) & 63)
    a.label("frame")
    gp0(0x2D80_8080)
    gp0(0x0000_0000);                 gp0((clut << 16) | (0 << 8) | 0)
    gp0(SCR_W - 1);                   gp0((8 << 16) | (0 << 8) | (TW - 1))
    gp0((SCR_H - 1) << 16);           gp0(((TH - 1) << 8) | 0)
    gp0(((SCR_H - 1) << 16) | (SCR_W - 1)); gp0((((TH - 1) << 8) | (TW - 1)))
    a.j("frame"); a.nop()
    w = a.words()
    img = bytearray(512 * 1024)
    for i, x in enumerate(w):
        img[i * 4:i * 4 + 4] = x.to_bytes(4, "little")
    open("sim/roms/ps1/texcheck4.bin", "wb").write(img)
    print("texcheck4.bin: %d instructions" % len(w))

def run4():
    rom = open("sim/roms/ps1/texcheck4.bin", "rb").read()
    req = urllib.request.Request("http://127.0.0.1:8080/api/nes/load", data=rom,
                                 headers={"Content-Type": "application/octet-stream"}, method="POST")
    print("load:", urllib.request.urlopen(req, timeout=60).read()[:40].decode())
    time.sleep(4)
    for attempt in range(8):
        d = urllib.request.urlopen("http://127.0.0.1:8080/api/vid/frame", timeout=20)
        data = d.read(); w = int(d.headers["X-Width"]); h = int(d.headers["X-Height"])
        if len(data) >= w * h * 2: break
        time.sleep(1.0)
    h = min(h, len(data) // (2 * w))
    print("frame %dx%d" % (w, h))
    alien = []; off = {}; checked = 0
    want = {pal_colour(i): i for i in range(16)}
    for y in range(min(h, SCR_H)):
        for x in range(min(w, SCR_W)):
            p = data[2 * (y * w + x)] | (data[2 * (y * w + x) + 1] << 8)
            checked += 1
            if p not in want:
                alien.append((x, y, p)); continue
            u = (x * (TW - 1)) // (SCR_W - 1)
            v = (y * (TH - 1)) // (SCR_H - 1)
            d_ = (want[p] - index4(u, v)) & 15
            if d_ not in (0, 1, 15):        # a texel either side is interpolation, not a fault
                off.setdefault(d_, []).append((x, y))
    bad = len(alien) + sum(len(z) for z in off.values())
    print("checked %d pixels: %d not a palette colour, %d wrong index -> %d bad (%.3f%%)"
          % (checked, len(alien), sum(len(z) for z in off.values()), bad, 100.0 * bad / max(checked, 1)))
    if alien:
        print("   not a palette colour, first few: %s" % ", ".join("(%d,%d)=%04x" % z for z in alien[:6]))
    for d_, where in sorted(off.items(), key=lambda kv: -len(kv[1]))[:6]:
        print("   index off by %+d: %d pixels, e.g. %s" % (d_ if d_ < 8 else d_ - 16, len(where), where[:3]))

def texel_g(u, v, gen):
    """As texel(), but the marker bits carry which UPLOAD it came from."""
    return (((u >> 5) & 1) << 14) | (((v >> 5) & 1) << 13) | ((gen & 7) << 10) | ((v & 31) << 5) | (u & 31)

def build_stale():
    """Upload a texture, draw with it, replace it in place, draw again. The
    second draw must show the second texture: if the engine keeps a cached copy
    of a line that has just been overwritten, the bottom half of the picture
    comes back with the first texture's marker -- which is what a game that
    streams its art into VRAM every frame would see as garbled textures."""
    a = Asm(org=0xBFC00000)
    a.li(T0, GP0); a.li(T1, GP1)
    def gp1(w): a.li(T2, w); a.sw(T2, 0, T1)
    def gp0(w): a.li(T2, w); a.sw(T2, 0, T0)
    gp1(0x0000_0000); gp1(0x0300_0000); gp1(0x0500_0000)
    gp1(0x0603_C060); gp1(0x0704_0010); gp1(0x0800_0001)
    gp0(0xE100_0108); gp0(0xE300_0000)
    gp0(0xE400_0000 | ((SCR_H - 1) << 10) | (SCR_W - 1))
    gp0(0xE500_0000); gp0(0xE600_0000)
    def upload(gen):
        gp0(0xA000_0000); gp0((TEX_Y << 16) | TEX_X); gp0((TH << 16) | TW)
        for v in range(TH):
            for u in range(0, TW, 2):
                gp0((texel_g(u + 1, v, gen) << 16) | texel_g(u, v, gen))
    def quad(y0, y1):
        gp0(0x2D80_8080)
        gp0((y0 << 16) | 0);            gp0((0 << 8) | 0)
        gp0((y0 << 16) | (SCR_W - 1));  gp0((0x108 << 16) | (0 << 8) | (TW - 1))
        gp0((y1 << 16) | 0);            gp0(((TH - 1) << 8) | 0)
        gp0((y1 << 16) | (SCR_W - 1));  gp0(((TH - 1) << 8) | (TW - 1))
    upload(1); quad(0, SCR_H // 2 - 1)
    upload(2); quad(SCR_H // 2, SCR_H - 1)
    a.label("done"); a.j("done"); a.nop()
    w = a.words()
    img = bytearray(512 * 1024)
    for i, x in enumerate(w):
        img[i * 4:i * 4 + 4] = x.to_bytes(4, "little")
    open("sim/roms/ps1/texstale.bin", "wb").write(img)
    print("texstale.bin: %d instructions" % len(w))

def run_stale():
    rom = open("sim/roms/ps1/texstale.bin", "rb").read()
    req = urllib.request.Request("http://127.0.0.1:8080/api/nes/load", data=rom,
                                 headers={"Content-Type": "application/octet-stream"}, method="POST")
    print("load:", urllib.request.urlopen(req, timeout=60).read()[:40].decode())
    time.sleep(5)
    for attempt in range(8):
        d = urllib.request.urlopen("http://127.0.0.1:8080/api/vid/frame", timeout=20)
        data = d.read(); w = int(d.headers["X-Width"]); h = int(d.headers["X-Height"])
        if len(data) >= w * h * 2: break
        time.sleep(1.0)
    h = min(h, len(data) // (2 * w))
    counts = {}
    for y in range(min(h, SCR_H)):
        half = 1 if y < SCR_H // 2 else 2
        for x in range(min(w, SCR_W)):
            p = data[2 * (y * w + x)] | (data[2 * (y * w + x) + 1] << 8)
            gen = (p >> 10) & 7
            counts[(half, gen)] = counts.get((half, gen), 0) + 1
    print("frame %dx%d" % (w, h))
    for half in (1, 2):
        tot = sum(v for (hh, g), v in counts.items() if hh == half)
        rows = sorted(((g, v) for (hh, g), v in counts.items() if hh == half), key=lambda t: -t[1])
        print("   half %d (drawn with texture %d): %s" % (half, half,
              ", ".join("texture %d: %d px (%.1f%%)" % (g, v, 100.0 * v / max(tot, 1)) for g, v in rows[:4])))

def build_grad():
    """A polygon whose first vertex is NOT the top of its bounding box, drawn
    right after one with a very different dv_dy. The row start used to be taken
    in the same clock as the last gradient was written, so this one began at the
    wrong row of its texture."""
    a = Asm(org=0xBFC00000)
    a.li(T0, GP0); a.li(T1, GP1)
    def gp1(w): a.li(T2, w); a.sw(T2, 0, T1)
    def gp0(w): a.li(T2, w); a.sw(T2, 0, T0)
    gp1(0x0000_0000); gp1(0x0300_0000); gp1(0x0500_0000)
    gp1(0x0603_C060); gp1(0x0704_0010); gp1(0x0800_0001)
    gp0(0xE100_0108); gp0(0xE300_0000)
    gp0(0xE400_0000 | ((SCR_H - 1) << 10) | (SCR_W - 1))
    gp0(0xE500_0000); gp0(0xE600_0000)
    gp0(0xA000_0000); gp0((TEX_Y << 16) | TEX_X); gp0((TH << 16) | TW)
    for v in range(TH):
        for u in range(0, TW, 2):
            gp0((texel_g(u + 1, v, 1) << 16) | texel_g(u, v, 1))
    # first: a quad with a big dv_dy, vertex 0 at the top
    gp0(0x2C80_8080)
    gp0((0 << 16) | 0);                 gp0((0 << 8) | 0)
    gp0((0 << 16) | (SCR_W - 1));       gp0((0x108 << 16) | (0 << 8) | (TW - 1))
    gp0((63 << 16) | 0);                gp0(((TH - 1) << 8) | 0)
    gp0((63 << 16) | (SCR_W - 1));      gp0(((TH - 1) << 8) | (TW - 1))
    # then: a quad with a small dv_dy whose FIRST vertex is the bottom left
    gp0(0x2C80_8080)
    gp0((131 << 16) | 0);               gp0((7 << 8) | 0)
    gp0((131 << 16) | (SCR_W - 1));     gp0((0x108 << 16) | (7 << 8) | (TW - 1))
    gp0((100 << 16) | 0);               gp0((0 << 8) | 0)
    gp0((100 << 16) | (SCR_W - 1));     gp0((0 << 8) | (TW - 1))
    a.label("done"); a.j("done"); a.nop()
    w = a.words()
    img = bytearray(512 * 1024)
    for i, x in enumerate(w):
        img[i * 4:i * 4 + 4] = x.to_bytes(4, "little")
    open("sim/roms/ps1/texgrad.bin", "wb").write(img)
    print("texgrad.bin: %d instructions" % len(w))

def run_grad():
    rom = open("sim/roms/ps1/texgrad.bin", "rb").read()
    req = urllib.request.Request("http://127.0.0.1:8080/api/nes/load", data=rom,
                                 headers={"Content-Type": "application/octet-stream"}, method="POST")
    print("load:", urllib.request.urlopen(req, timeout=60).read()[:40].decode())
    time.sleep(5)
    for attempt in range(8):
        d = urllib.request.urlopen("http://127.0.0.1:8080/api/vid/frame", timeout=20)
        data = d.read(); w = int(d.headers["X-Width"]); h = int(d.headers["X-Height"])
        if len(data) >= w * h * 2: break
        time.sleep(1.0)
    y0, y1 = 100, 131
    wrong = 0; tot = 0; shown = 0
    for y in range(y0, y1 + 1):
        for x in range(SCR_W):
            p = data[2 * (y * w + x)] | (data[2 * (y * w + x) + 1] << 8)
            du = (p & 31) | (((p >> 14) & 1) << 5)
            dv = ((p >> 5) & 31) | (((p >> 13) & 1) << 5)
            eu = (x * (TW - 1)) // (SCR_W - 1)
            ev = ((y - y0) * 7) // (y1 - y0)
            tot += 1
            if abs(du - eu) > 1 or abs(dv - ev) > 1:
                wrong += 1
                if shown < 4:
                    print("      (%3d,%3d) sampled texel (%2d,%2d), should be about (%2d,%2d)" % (x, y, du, dv, eu, ev))
                    shown += 1
    print("   rows %d..%d: %d of %d pixels sampled the wrong texel  (%s)" %
          (y0, y1, wrong, tot, "PASS" if wrong == 0 else "FAIL"))

def build_dma():
    """The same replace-and-draw test, except the second texture goes to VRAM
    by DMA -- which is how a game uploads its art, and the one path the earlier
    tests never touch."""
    a = Asm(org=0xBFC00000)
    a.li(T0, GP0); a.li(T1, GP1)
    def gp1(w): a.li(T2, w); a.sw(T2, 0, T1)
    def gp0(w): a.li(T2, w); a.sw(T2, 0, T0)
    gp1(0x0000_0000); gp1(0x0300_0000); gp1(0x0500_0000)
    gp1(0x0603_C060); gp1(0x0704_0010); gp1(0x0800_0001)
    gp0(0xE100_0108); gp0(0xE300_0000)
    gp0(0xE400_0000 | ((SCR_H - 1) << 10) | (SCR_W - 1))
    gp0(0xE500_0000); gp0(0xE600_0000)
    def quad(y0, y1):
        gp0(0x2D80_8080)
        gp0((y0 << 16) | 0);            gp0((0 << 8) | 0)
        gp0((y0 << 16) | (SCR_W - 1));  gp0((0x108 << 16) | (0 << 8) | (TW - 1))
        gp0((y1 << 16) | 0);            gp0(((TH - 1) << 8) | 0)
        gp0((y1 << 16) | (SCR_W - 1));  gp0(((TH - 1) << 8) | (TW - 1))
    a.label("top")
    # texture 1 the plain way, and draw the top half with it
    gp0(0xA000_0000); gp0((TEX_Y << 16) | TEX_X); gp0((TH << 16) | TW)
    for v in range(TH):
        for u in range(0, TW, 2):
            gp0((texel_g(u + 1, v, 1) << 16) | texel_g(u, v, 1))
    quad(0, SCR_H // 2 - 1)
    # texture 2 built in RAM at 0x80100000, then pushed to the GPU by DMA 2
    a.li(S0, 0x8010_0000)
    words = [0xA000_0000, (TEX_Y << 16) | TEX_X, (TH << 16) | TW]
    for v in range(TH):
        for u in range(0, TW, 2):
            words.append((texel_g(u + 1, v, 2) << 16) | texel_g(u, v, 2))
    while len(words) % 16:
        words.append(0x0000_0000)          # GP0 nop: never let the tail be uninitialised RAM
    for i, wd in enumerate(words):
        a.li(T3, wd); a.sw(T3, i * 4, S0)
    a.li(T4, 0x1F80_10A0); a.li(T3, 0x0010_0000); a.sw(T3, 0, T4)      # D2_MADR
    nblocks = len(words) // 16
    a.li(T3, (nblocks << 16) | 16);        a.sw(T3, 4, T4)             # D2_BCR
    a.li(T5, 0x1F80_10F0); a.lw(T3, 0, T5); a.nop(); a.ori(T3, T3, 0x0800); a.sw(T3, 0, T5)
    gp1(0x0400_0002)                                                    # DMA direction: to the GPU
    a.li(T3, 0x0100_0201);                 a.sw(T3, 8, T4)             # D2_CHCR: go
    a.label("wait"); a.lw(T3, 8, T4); a.nop(); a.li(T6, 0x0100_0000); a.and_(T3, T3, T6)
    a.bne(T3, ZERO, "wait"); a.nop()
    gp1(0x0400_0000)
    quad(SCR_H // 2, SCR_H - 1)
    a.j("top"); a.nop()
    w = a.words()
    img = bytearray(512 * 1024)
    for i, x in enumerate(w):
        img[i * 4:i * 4 + 4] = x.to_bytes(4, "little")
    open("sim/roms/ps1/texdma.bin", "wb").write(img)
    print("texdma.bin: %d instructions" % len(w))

def run_dma(flags=None):
    rom = open("sim/roms/ps1/texdma.bin", "rb").read()
    req = urllib.request.Request("http://127.0.0.1:8080/api/nes/load", data=rom,
                                 headers={"Content-Type": "application/octet-stream"}, method="POST")
    print("load:", urllib.request.urlopen(req, timeout=60).read()[:40].decode())
    time.sleep(3)
    if flags is not None:
        sys.path.insert(0, os.path.join(HERE, "..", "pc"))
        import fpgalink as fl
        fl.Link(fl.DEFAULT_HOST, 5005, timeout=1.0, retries=4).write(0x0008_0000 + 0xEC, flags)
        print("ctrl 0xEC = 0x%05x" % flags)
    time.sleep(3)
    for attempt in range(8):
        d = urllib.request.urlopen("http://127.0.0.1:8080/api/vid/frame", timeout=20)
        data = d.read(); w = int(d.headers["X-Width"]); h = int(d.headers["X-Height"])
        if len(data) >= w * h * 2: break
        time.sleep(1.0)
    h = min(h, len(data) // (2 * w))
    counts = {}
    for y in range(min(h, SCR_H)):
        half = 1 if y < SCR_H // 2 else 2
        for x in range(min(w, SCR_W)):
            p = data[2 * (y * w + x)] | (data[2 * (y * w + x) + 1] << 8)
            g = (p >> 10) & 7
            counts[(half, g)] = counts.get((half, g), 0) + 1
    print("frame %dx%d" % (w, h))
    # every texel names its own (u, v): so a wrong pixel can say whether it is the
    # right texel from the wrong upload, or the wrong texel altogether
    right_pos_wrong_gen = 0; wrong_pos = 0; samples = []
    y0, y1 = SCR_H // 2, SCR_H - 1
    for y in range(y0, min(h, SCR_H)):
        for x in range(0, min(w, SCR_W)):
            p = data[2 * (y * w + x)] | (data[2 * (y * w + x) + 1] << 8)
            g = (p >> 10) & 7
            if g == 2: continue
            du = (p & 31) | (((p >> 14) & 1) << 5)
            dv = ((p >> 5) & 31) | (((p >> 13) & 1) << 5)
            eu = (x * (TW - 1)) // (SCR_W - 1)
            ev = ((y - y0) * (TH - 1)) // (y1 - y0)
            if abs(du - eu) <= 1 and abs(dv - ev) <= 1: right_pos_wrong_gen += 1
            else:
                wrong_pos += 1
                if len(samples) < 6: samples.append((x, y, p, du, dv, eu, ev, g))
    print("   bad pixels: %d at the right texel from the wrong upload, %d at the wrong texel" %
          (right_pos_wrong_gen, wrong_pos))
    for x, y, p, du, dv, eu, ev, g in samples:
        print("      screen (%3d,%3d) reads %04x: texel (%2d,%2d) gen %d, expected texel (%2d,%2d)" %
              (x, y, p, du, dv, g, eu, ev))
    for half in (1, 2):
        tot = sum(v for (hh, g), v in counts.items() if hh == half)
        rows = sorted(((g, v) for (hh, g), v in counts.items() if hh == half), key=lambda t: -t[1])
        print("   half %d (should be texture %d): %s" % (half, half,
              ", ".join("texture %d: %d px (%.1f%%)" % (g, v, 100.0 * v / max(tot, 1)) for g, v in rows[:4])))

def build():
    a = Asm(org=0xBFC00000)
    a.li(T0, GP0); a.li(T1, GP1)
    def gp1(w): a.li(T2, w); a.sw(T2, 0, T1)
    def gp0(w): a.li(T2, w); a.sw(T2, 0, T0)
    gp1(0x0000_0000)                      # reset
    gp1(0x0300_0000)                      # display on
    gp1(0x0500_0000)                      # display area (0,0)
    gp1(0x0603_C060)                      # horizontal range, as the BIOS sets it
    gp1(0x0704_0010)                      # vertical range
    gp1(0x0800_0001)                      # 320x240, 15 bit, no interlace
    gp0(0xE100_0108)                      # draw mode: texture page x=8, y=0, FIFTEEN-bit (bits 8:7 = 2), dither off
    gp0(0xE300_0000)                      # drawing area top-left (0,0)
    gp0(0xE400_0000 | ((SCR_H - 1) << 10) | (SCR_W - 1))
    gp0(0xE500_0000)                      # drawing offset (0,0)
    gp0(0xE600_0000)                      # mask: draw everything
    # --- the texture, sent as CPU -> VRAM ---
    gp0(0xA000_0000)
    gp0((TEX_Y << 16) | TEX_X)
    gp0((TH << 16) | TW)
    for v in range(TH):
        for u in range(0, TW, 2):
            gp0((texel(u + 1, v) << 16) | texel(u, v))
    # --- draw it, for ever: a textured quad, raw (no shading), opaque ---
    a.label("frame")
    gp0(0x2D80_8080)                                   # textured quad, raw texture
    gp0(0x0000_0000); gp0(0x0000_0000 | (0 << 8) | 0)  # v0 (0,0)      uv (0,0) + clut
    gp0(SCR_W - 1);   gp0((0 << 8) | (TW - 1) | (0x108 << 16))  # v1, uv (63,0), texture page + 15-bit depth
    gp0((SCR_H - 1) << 16); gp0(((TH - 1) << 8) | 0)   # v2 (0,h)      uv (0,63)
    gp0(((SCR_H - 1) << 16) | (SCR_W - 1)); gp0(((TH - 1) << 8) | (TW - 1))
    a.j("frame"); a.nop()
    w = a.words()
    img = bytearray(512 * 1024)
    for i, x in enumerate(w):
        img[i * 4:i * 4 + 4] = x.to_bytes(4, "little")
    open("sim/roms/ps1/texcheck.bin", "wb").write(img)
    print("texcheck.bin: %d instructions" % len(w))

def run():
    import fpgalink as fl
    rom = open("sim/roms/ps1/texcheck.bin", "rb").read()
    req = urllib.request.Request("http://127.0.0.1:8080/api/nes/load", data=rom,
                                 headers={"Content-Type": "application/octet-stream"}, method="POST")
    print("load:", urllib.request.urlopen(req, timeout=60).read()[:40].decode())
    time.sleep(4)
    data = w = h = None
    for attempt in range(8):                       # the size settles after a mode change
        d = urllib.request.urlopen("http://127.0.0.1:8080/api/vid/frame", timeout=20)
        data = d.read(); w = int(d.headers["X-Width"]); h = int(d.headers["X-Height"])
        if len(data) >= w * h * 2:
            break
        time.sleep(1.0)
    h = min(h, len(data) // (2 * w))
    print("frame %dx%d (%d bytes)" % (w, h, len(data)))
    alien = []          # pixels that are not a texel of ours at all
    off = {}            # texels fetched from the wrong place, by how far off
    checked = 0
    for y in range(min(h, SCR_H)):
        for x in range(min(w, SCR_W)):
            p = data[2 * (y * w + x)] | (data[2 * (y * w + x) + 1] << 8)
            checked += 1
            got = decode(p)
            if got is None:
                alien.append((x, y, p)); continue
            u = (x * (TW - 1)) // (SCR_W - 1)
            v = (y * (TH - 1)) // (SCR_H - 1)
            du, dv = got[0] - u, got[1] - v
            if abs(du) > 1 or abs(dv) > 1:
                off.setdefault((du, dv), []).append((x, y))
    bad = len(alien) + sum(len(z) for z in off.values())
    print("checked %d pixels: %d not from this texture, %d from the wrong texel -> %d bad (%.3f%%)"
          % (checked, len(alien), sum(len(z) for z in off.values()), bad, 100.0 * bad / max(checked, 1)))
    if alien:
        print("   not ours, first few: %s" % ", ".join("(%d,%d)=%04x" % a for a in alien[:6]))
    for (du, dv), where in sorted(off.items(), key=lambda kv: -len(kv[1]))[:6]:
        print("   wrong texel by u%+d v%+d : %d pixels, e.g. %s" % (du, dv, len(where), where[:3]))

if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "build"
    {"build": build, "run": run, "build4": build4, "run4": run4, "buildstale": build_stale, "runstale": run_stale, "builddma": build_dma, "rundma": run_dma, "buildgrad": build_grad, "rungrad": run_grad}[what](*([int(sys.argv[2], 0)] if what == "rundma" and len(sys.argv) > 2 else []))
