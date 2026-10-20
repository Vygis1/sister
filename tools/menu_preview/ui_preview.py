"""ui_preview.py - the menu's pages as the TV would show them, without the board:
esp32/console/screens.h compiled on the PC (ui_preview.cpp), its cells rendered as osd.v
(version 2) draws them -- the font from rtl/osd_font.v for glyphs 0-127, the menu's own
glyphs as loaded, the palette, cell backgrounds, the gradient.

    python tools/menu_preview/ui_preview.py home|games|settings|wifi|keyboard|qr|tester|
                                            pairing|controllers|message|splash [T]
        -> build/ui_<which>.png        (T: the splash's frame)
"""
import os, re, subprocess, sys
from PIL import Image

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.join(here, '..', '..')
which = sys.argv[1] if len(sys.argv) > 1 else 'home'
t = sys.argv[2] if len(sys.argv) > 2 else '200'
exe = os.path.join(root, 'build', 'ui_preview.exe')
clang = r'C:\Program Files\AMD\ROCm\7.1\bin\clang++.exe'
if not os.path.exists(clang):
    clang = 'clang++'
src = os.path.join(here, 'ui_preview.cpp')
qr = os.path.join(root, 'esp32', 'console', 'qrgen.c')
if not os.path.exists(exe) or any(os.path.getmtime(f) > os.path.getmtime(exe) for f in
        [src, qr] + [os.path.join(root, 'esp32', 'console', n) for n in ('ui.h', 'screens.h', 'art.h')]):
    obj = os.path.join(root, 'build', 'qrgen.o')
    subprocess.check_call([clang, '-x', 'c', '-O1', '-w', '-c', qr, '-o', obj])
    subprocess.check_call([clang, '-std=c++17', '-O1', '-w', src, obj, '-o', exe])
lines = subprocess.check_output([exe, which, t]).decode().split('\n')
ctrl = int(lines[0])
pal = [int(lines[1 + i], 16) for i in range(8)]
glyph = [0] * 2048
for ad, v in re.findall(r"10'h([0-9A-F]{3}): q <= 8'h([0-9A-F]{2});", open(os.path.join(root, 'rtl', 'osd_font.v')).read()):
    glyph[int(ad, 16)] = int(v, 16)
for i in range(2048):
    s, v = lines[9 + i].split()
    if s == '1':
        glyph[i] = int(v, 16)
cells = [int(lines[9 + 2048 + i], 16) for i in range(1200)]


def c24(v):
    return ((v >> 16) & 255, (v >> 8) & 255, v & 255)


im = Image.new('RGB', (640, 480))
px = im.load()
# a game behind the menu (ctrl bit 1: dimmed, as osd.v): any picture in build/game_bg.png, else bars
game = None
gp = os.path.join(root, 'build', 'game_bg.png')
if os.path.exists(gp):
    game = Image.open(gp).convert('RGB').resize((640, 480)).load()


def gpx(x, y):
    if game:
        return game[x, y]
    return ((x * 255 // 640), 120 + (y * 100 // 480) % 120, 200 - (x * 150 // 640))


def gbit(g, r, c):
    if r < 0 or r > 7 or c < 0 or c > 7:
        return 0
    return (glyph[g * 8 + r] >> c) & 1


for y in range(480):
    gt = (59 - (y >> 3)) & 63
    grad = (8 + (gt >> 2), 10 + (gt >> 2) + (gt >> 4), 24 + (gt >> 1))
    for x in range(640):
        cv = cells[(y >> 4) * 40 + (x >> 4)]
        g = cv & 0xFF
        r, c, sx, sy = (y >> 1) & 7, (x >> 1) & 7, x & 1, y & 1
        P = gbit(g, r, c)
        txt = 0x20 <= g < 0x80
        if txt:   # Scale2x and the shadow, as osd.v
            A, D, C, B, UL = gbit(g, r - 1, c), gbit(g, r + 1, c), gbit(g, r, c - 1), gbit(g, r, c + 1), gbit(g, r - 1, c - 1)
            E0 = A if (C == A and C != D and A != B) else P
            E1 = B if (A == B and A != C and B != D) else P
            E2 = C if (D == C and D != B and C != A) else P
            E3 = D if (B == D and B != A and D != C) else P
            fg = (E3 if sx else E2) if sy else (E1 if sx else E0)
            sh = (not fg) and UL
        else:
            fg, sh = P, 0
        ink = c24(pal[((cv >> 9) & 3) | (((cv >> 12) & 1) << 2)])
        if cv & 0x100:
            bg = (0x2C, 0x58, 0xC8)
        elif cv & 0x2000:
            bg = c24(pal[(cv >> 14) & 7])
        elif cv & 0x800:
            bg = (0x26, 0x32, 0x5E)
        elif ctrl & 2:
            q = gpx(x, y)
            bg = ((q[0] >> 2) + 8, (q[1] >> 2) + 8, (q[2] >> 2) + 24)
        elif ctrl & 4:
            bg = (0, 0, 0)
        else:
            bg = grad
        px[x, y] = ink if fg else tuple(v >> 1 for v in bg) if sh else bg
out = os.path.join(root, 'build', 'ui_%s.png' % which)
im.save(out)
print(out)
