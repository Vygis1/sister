"""Does the drawing engine draw the SAME thing twice? The board decides.

    python tools/ps1determ.py build     write sim/roms/ps1/determ.bin
    python tools/ps1determ.py run       load it and count distinct pictures
    python tools/ps1determ.py           build, then run

The program uploads one texture and then draws the SAME forty shaded textured
triangles, at the same coordinates, for ever. Nothing animates, nothing moves,
there is no game and no double buffering -- so every frame must be identical,
pixel for pixel. If the frames that come back are not identical, the drawing
engine renders the same commands two different ways, and that is a race in the
engine rather than anything the game did.

This exists because the same question could not be settled inside the game: the
character keeps animating even with the game paused, so a frame that differs
might legitimately differ. Here nothing can.
"""
import os, sys, time, urllib.request
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE); sys.path.insert(0, os.path.join(HERE, "..", "pc"))
from mipsasm import *

GP0, GP1 = 0x1F801810, 0x1F801814
SCR_W, SCR_H = 256, 224
TEX_X, TEX_Y = 512, 256           # the texture page: page x = 8, page y = 1
TW, TH = 64, 32
ROM = "sim/roms/ps1/determ.bin"


def texel(u, v):
    """Fifteen bits, never zero (zero is transparent), varying in both axes so a
    wrong texel fetch shows as a wrong colour rather than as nothing."""
    return (1 << 14) | (((u * 3) & 31) << 5) | ((v * 5) & 31)


# The triangles. Fixed coordinates, deliberately at angles -- a shear shows up
# on a sloped edge and hides on an axis-aligned one -- and overlapping, so the
# engine reads back what it has already written.
def tris():
    out = []
    for j in range(40):
        out.append((
            (20 + j,       30 + j * 3,   0,        0),
            (80 + j * 2,   40 + j * 3,   TW - 1,   0),
            (60 + j,       120 + j * 2,  0,        TH - 1),
        ))
    return out


def build():
    a = Asm(org=0xBFC00000)
    a.li(T0, GP0); a.li(T1, GP1)
    def gp1(w): a.li(T2, w); a.sw(T2, 0, T1)
    def gp0(w): a.li(T2, w); a.sw(T2, 0, T0)

    gp1(0x0000_0000); gp1(0x0300_0000); gp1(0x0500_0000)
    gp1(0x0603_C060); gp1(0x0704_0010); gp1(0x0800_0001)
    gp0(0xE100_0000 | (2 << 7) | (1 << 4) | 8)      # page x=8, y=1, fifteen-bit
    gp0(0xE300_0000)
    gp0(0xE400_0000 | ((SCR_H - 1) << 10) | (SCR_W - 1))
    gp0(0xE500_0000); gp0(0xE600_0000)

    # the texture, once
    gp0(0xA000_0000); gp0((TEX_Y << 16) | TEX_X); gp0((TH << 16) | TW)
    for v in range(TH):
        for u in range(0, TW, 2):
            gp0((texel(u + 1, v) << 16) | texel(u, v))

    # and the same scene, for ever
    texpage = (2 << 7) | (1 << 4) | 8
    a.label("frame")
    # clear, so every frame starts from the same screen rather than accumulating
    gp0(0x0200_0020); gp0(0x0000_0000); gp0((SCR_H << 16) | SCR_W)
    for (x0, y0, u0, v0), (x1, y1, u1, v1), (x2, y2, u2, v2) in tris():
        gp0(0x3480_8080)
        gp0(((y0 & 0xFFFF) << 16) | (x0 & 0xFFFF)); gp0((v0 << 8) | u0)
        gp0(0x00C0_C0C0)
        gp0(((y1 & 0xFFFF) << 16) | (x1 & 0xFFFF)); gp0((texpage << 16) | (v1 << 8) | u1)
        gp0(0x0080_8080)
        gp0(((y2 & 0xFFFF) << 16) | (x2 & 0xFFFF)); gp0((v2 << 8) | u2)
    # a short idle gap, so the engine is quiet long enough for a capture to arm
    a.li(T3, 200000)
    a.label("wait")
    a.addiu(T3, T3, -1)
    a.bne(T3, ZERO, "wait"); a.nop()
    a.j("frame"); a.nop()

    w = a.words()
    img = bytearray(512 * 1024)
    for i, x in enumerate(w):
        img[i * 4:i * 4 + 4] = x.to_bytes(4, "little")
    open(ROM, "wb").write(img)
    print("%s: %d instructions, %d triangles a frame" % (ROM, len(w), len(tris())))


def grab(n, secs=60):
    """Take frames by the board's OWN frame id, not by content. Skipping frames
    whose content repeats cannot tell a stable picture from a stalled capture --
    which is how a first run of this reported "only 1 frame came back"."""
    fs = []; lastid = None; t0 = time.time(); w = h = 0
    while len(fs) < n and time.time() - t0 < secs:
        try:
            d = urllib.request.urlopen("http://127.0.0.1:8080/api/vid/frame", timeout=20)
            b = d.read()
        except Exception:
            continue
        w, h = int(d.headers["X-Width"]), int(d.headers["X-Height"])
        fid = d.headers.get("X-Frame")
        if len(b) < w * h * 2 or fid == lastid:
            time.sleep(0.02); continue
        lastid = fid
        fs.append(b[:w * h * 2])
    return fs, w, h


def run():
    rom = open(ROM, "rb").read()
    req = urllib.request.Request("http://127.0.0.1:8080/api/nes/load", data=rom,
                                 headers={"Content-Type": "application/octet-stream"},
                                 method="POST")
    print("load:", urllib.request.urlopen(req, timeout=60).read()[:40].decode().strip())
    # The image goes into the boot slot; the console has to be RESET to run it.
    # Without this the game carries on and the test measures the game, which is
    # exactly what it exists to avoid.
    sys.path.insert(0, os.path.join(HERE, "..", "pc"))
    import fpgalink as fl
    l = fl.Link(fl.DEFAULT_HOST)
    r = l.read(0x0008_0000 + 0x04)
    l.write(0x0008_0000 + 0x04, r & ~1); time.sleep(0.3)
    l.write(0x0008_0000 + 0x04, r | 1)
    print("console reset; waiting for it to draw")
    time.sleep(6)
    print("  pc now %08x" % l.read(0x0008_0000 + 0x14))
    fs, w, h = grab(30)
    if len(fs) < 4:
        print("only %d frames came back -- nothing to compare" % len(fs)); return
    lit = sum(1 for k in range(0, len(fs[0]), 2) if fs[0][k] or fs[0][k + 1])
    print("%d frames of %dx%d, %d pixels lit in the first" % (len(fs), w, h, lit))
    if lit < 2000:
        print("the scene is not being drawn -- nothing to compare"); return
    uniq = {}
    for i, f in enumerate(fs):
        uniq.setdefault(f, []).append(i)
    print("DISTINCT PICTURES: %d of %d frames" % (len(uniq), len(fs)))
    if len(uniq) == 1:
        print("  the engine draws the same commands the same way every time")
        return
    a, b = fs[0], next(f for f in fs if f != fs[0])
    diff = sum(1 for k in range(0, len(a), 2) if a[k:k + 2] != b[k:k + 2])
    print("  two of them differ in %d pixels (%.2f%% of the screen)"
          % (diff, 100.0 * diff / (w * h)))
    rows = {}
    for k in range(0, len(a), 2):
        if a[k:k + 2] != b[k:k + 2]:
            rows[(k // 2) // w] = rows.get((k // 2) // w, 0) + 1
    ys = sorted(rows)
    print("  rows touched: %d..%d" % (ys[0], ys[-1]))
    print("  THE DRAWING ENGINE IS NOT DETERMINISTIC ON THIS BOARD")


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "both"
    if what in ("build", "both"): build()
    if what in ("run", "both"): run()
