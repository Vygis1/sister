"""preview.py - what the menu looks like, without the board: the drawing parts of
esp32/console/menu.h (its screen helpers and draw()) compiled on the PC with
preview.cpp's stand-ins, their cells rendered as rtl/osd.v draws them (the font from
rtl/osd_font.v, doubled; the gradient, bars, highlight and inks as osd.v has them).

    python tools/menu_preview/preview.py consoles|games|message  -> build/menu_<which>.png
"""
import os, re, subprocess, sys
from PIL import Image

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.join(here, '..', '..')
which = sys.argv[1] if len(sys.argv) > 1 else 'consoles'

src = open(os.path.join(root, 'esp32', 'console', 'menu.h'), encoding='utf-8').read()
a = src.index('// --- the screen: 40 x 30 cells')
b = src.index('// --- the card: a folder in /roms for each console')
c = src.index('static int level = 0;')
d = src.index('// --- the pad ---')
open(os.path.join(here, 'cut.h'), 'w', encoding='utf-8').write(src[a:b] + '\n' + src[c:d])
exe = os.path.join(root, 'build', 'menu_preview.exe')
clang = r'C:\Program Files\AMD\ROCm\7.1\bin\clang++.exe'
if not os.path.exists(clang):
    clang = 'clang++'
subprocess.check_call([clang, '-std=c++17', '-O1', '-w', '-o', exe, os.path.join(here, 'preview.cpp')])
cells = [int(l, 16) for l in subprocess.check_output([exe, which]).decode().split()]

font = [0] * 1024
for ad, v in re.findall(r"10'h([0-9A-F]{3}): q <= 8'h([0-9A-F]{2});", open(os.path.join(root, 'rtl', 'osd_font.v')).read()):
    font[int(ad, 16)] = int(v, 16)
ink = {0: (0xF0, 0xF0, 0xF0), 1: (0xFF, 0xE0, 0x40), 2: (0x88, 0x90, 0xA8), 3: (0x60, 0xE0, 0x70)}
im = Image.new('RGB', (640, 480))
px = im.load()
for y in range(480):
    gt = (59 - (y >> 3)) & 63
    grad = (8 + (gt >> 2), 10 + (gt >> 2) + (gt >> 4), 24 + (gt >> 1))
    for x in range(640):
        cv = cells[(y >> 4) * 40 + (x >> 4)]
        fg = (font[(cv & 0x7F) * 8 + ((y >> 1) & 7)] >> ((x >> 1) & 7)) & 1
        bg = (0x2C, 0x58, 0xC8) if cv & 0x100 else (0x26, 0x32, 0x5E) if cv & 0x800 else grad
        px[x, y] = ink[(cv >> 9) & 3] if fg else bg
out = os.path.join(root, 'build', 'menu_%s.png' % which)
im.save(out)
print(out)
