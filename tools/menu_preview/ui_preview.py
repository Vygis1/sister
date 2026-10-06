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
for y in range(480):
    gt = (59 - (y >> 3)) & 63
    grad = (8 + (gt >> 2), 10 + (gt >> 2) + (gt >> 4), 24 + (gt >> 1))
    for x in range(640):
        cv = cells[(y >> 4) * 40 + (x >> 4)]
        g = cv & 0xFF
        fg = (glyph[g * 8 + ((y >> 1) & 7)] >> ((x >> 1) & 7)) & 1
        ink = c24(pal[((cv >> 9) & 3) | (((cv >> 12) & 1) << 2)])
        if cv & 0x100:
            bg = (0x2C, 0x58, 0xC8)
        elif cv & 0x2000:
            bg = c24(pal[(cv >> 14) & 7])
        elif cv & 0x800:
            bg = (0x26, 0x32, 0x5E)
        elif ctrl & 4:
            bg = (0, 0, 0)
        else:
            bg = grad
        px[x, y] = ink if fg else bg
out = os.path.join(root, 'build', 'ui_%s.png' % which)
im.save(out)
print(out)
