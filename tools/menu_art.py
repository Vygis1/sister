"""menu_art.py - the menu's own tiles for osd.v (version 2): esp32/console/art.h.

    python tools/menu_art.py          -> esp32/console/art.h, build/menu_logo.png (8x, to look at)

osd.v draws a cell as an 8 x 8 glyph (doubled on the screen) in one ink over one background,
both from its palette -- so a picture is cut into 8 x 8 tiles of at most two colours each.
The logo is drawn here with plain shapes in the splash's palette, cut into tiles, and every
tile checked: three colours in one tile is an error, not a guess.

Glyphs (osd.v's 128-255):
  0x80-0x8F  quadrant blocks: bit 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right (the
             QR code, the big letters)
  0x90-0x9F  icons: the pad's cross / circle / square / triangle, Wi-Fi 0-3 bars, Bluetooth,
             a pad, a tick, a padlock, a gear, a small heart, a left and right arrow
  0xA0-      the logo's tiles (as many as it has distinct ones)
"""
import os
from PIL import Image, ImageDraw

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')

# the splash's palette (the ESP32 loads it into osd.v); 7 is black, the splash's background
SPLASH_PAL = [0xF0F0F0, 0xFFE040, 0x8890A8, 0x60E070, 0xFF7FA8, 0xFF5050, 0xF2BC94, 0x000000]
# the menu's: the same but 6 a blue for the cross
MENU_PAL = [0xF0F0F0, 0xFFE040, 0x8890A8, 0x60E070, 0xFF7FA8, 0xFF5050, 0x5C8CFF, 0x000000]
WHITE, YELLOW, GREY, GREEN, PINK, RED, SKIN, BLACK = range(8)


def rgb(i, pal=SPLASH_PAL):
    v = pal[i]
    return ((v >> 16) & 255, (v >> 8) & 255, v & 255)


# --- the logo: the mascot, 64 x 64, in palette colours -------------------------------------------
W, H = 64, 64
img = Image.new('P', (W, H), BLACK)
img.putpalette(sum([list(rgb(i)) for i in range(8)], []) + [0] * (256 - 8) * 3)
d = ImageDraw.Draw(img)
# The tip (pink) sits in rows 0-23 and the body (skin) from row 24 down, so no tile holds both:
# the line between them is black and on a tile boundary.
# tip: a dome, a little wider than the body
d.ellipse([16, 1, 47, 30], fill=BLACK)
d.ellipse([18, 3, 45, 28], fill=PINK)
d.rectangle([16, 24, 47, 31], fill=BLACK)          # cut flat at the tile line (row 24)
d.line([30, 7, 30, 12], fill=BLACK, width=2)       # the little slit on top
# a shine on the tip (in a tile of pink alone: two colours)
d.ellipse([33, 9, 38, 12], fill=WHITE)
# body: a capsule
d.rectangle([20, 24, 43, 49], fill=BLACK)
d.rectangle([22, 25, 41, 49], fill=SKIN)
d.line([16, 24, 47, 24], fill=BLACK)
# balls
d.ellipse([8, 40, 33, 63], fill=BLACK)
d.ellipse([10, 42, 31, 61], fill=SKIN)
d.ellipse([30, 40, 55, 63], fill=BLACK)
d.ellipse([32, 42, 53, 61], fill=SKIN)
d.line([31, 46, 31, 58], fill=BLACK, width=2)      # between them
d.rectangle([22, 40, 41, 47], fill=SKIN)           # the body runs into them
# the face, on the body: eyes and a smile
d.rectangle([26, 29, 28, 32], fill=BLACK)
d.rectangle([35, 29, 37, 32], fill=BLACK)
d.arc([26, 30, 37, 39], start=20, end=160, fill=BLACK, width=2)
px = img.load()

# cut into tiles, two colours each
tiles, cells = [], []      # tiles: (rows[8]); cells: (glyph index or -1, ink, bg)
for ty in range(H // 8):
    for tx in range(W // 8):
        cols = sorted({px[tx * 8 + x, ty * 8 + y] for y in range(8) for x in range(8)})
        if len(cols) > 2:
            raise SystemExit('logo tile (%d,%d) has %d colours: %s' % (tx, ty, len(cols), cols))
        if len(cols) == 1:
            cells.append((-1, cols[0], cols[0]))
            continue
        bg = BLACK if BLACK in cols else cols[0]
        ink = cols[1] if cols[0] == bg else cols[0]
        rows = [sum(1 << x for x in range(8) if px[tx * 8 + x, ty * 8 + y] == ink) for y in range(8)]
        if rows in tiles:
            g = tiles.index(rows)
        else:
            tiles.append(rows); g = len(tiles) - 1
        cells.append((g, ink, bg))
LOGO_TILES = 0xA0
assert LOGO_TILES + len(tiles) <= 0x100, len(tiles)
big = img.convert('RGB').resize((W * 8, H * 8), Image.NEAREST)
os.makedirs(os.path.join(root, 'build'), exist_ok=True)
big.save(os.path.join(root, 'build', 'menu_logo.png'))


# --- icons, 8 x 8 ---------------------------------------------------------------------------
def bits(art):
    rows = [r for r in art.strip('\n').split('\n')]
    assert len(rows) == 8, art
    return [sum(1 << x for x, ch in enumerate(r.ljust(8)[:8]) if ch == '#') for r in rows]


ICONS = [
    ('cross', '''
#......#
.#....#.
..#..#..
...##...
...##...
..#..#..
.#....#.
#......#'''),
    ('circle', '''
..####..
.#....#.
#......#
#......#
#......#
#......#
.#....#.
..####..'''),
    ('square', '''
........
.######.
.#....#.
.#....#.
.#....#.
.#....#.
.######.
........'''),
    ('triangle', '''
...##...
...##...
..#..#..
..#..#..
.#....#.
.#....#.
########
........'''),
    ('wifi0', '''
........
........
........
........
........
........
#.......
#.......'''),
    ('wifi1', '''
........
........
........
........
..#.....
..#.....
#.#.....
#.#.....'''),
    ('wifi2', '''
........
........
....#...
....#...
..#.#...
..#.#...
#.#.#...
#.#.#...'''),
    ('wifi3', '''
......#.
......#.
....#.#.
....#.#.
..#.#.#.
..#.#.#.
#.#.#.#.
#.#.#.#.'''),
    ('bt', '''
...#....
...##...
.#.#.#..
..###...
..###...
.#.#.#..
...##...
...#....'''),
    ('pad', '''
........
.##..##.
########
##.##.##
#...####
##.###.#
########
##....##'''),
    ('tick', '''
........
.......#
......#.
.....#..
#...#...
.#.#....
..#.....
........'''),
    ('lock', '''
..####..
.#....#.
.#....#.
########
###..###
###..###
########
........'''),
    ('gear', '''
...##...
.######.
.##..##.
###..###
###..###
.##..##.
.######.
...##...'''),
    ('heart', '''
........
.##..##.
########
########
.######.
..####..
...##...
........'''),
    ('left', '''
........
...#....
..##....
.#######
.#######
..##....
...#....
........'''),
    ('right', '''
........
....#...
....##..
#######.
#######.
....##..
....#...
........'''),
]
assert len(ICONS) == 16

# --- the big letters: 5 x 7, drawn in quadrant blocks (2 x 2 letter pixels a cell) ---------
FONT5 = {
    'A': ['.###.', '#...#', '#...#', '#####', '#...#', '#...#', '#...#'],
    'B': ['####.', '#...#', '#...#', '####.', '#...#', '#...#', '####.'],
    'C': ['.###.', '#...#', '#....', '#....', '#....', '#...#', '.###.'],
    'D': ['####.', '#...#', '#...#', '#...#', '#...#', '#...#', '####.'],
    'E': ['#####', '#....', '#....', '####.', '#....', '#....', '#####'],
    'F': ['#####', '#....', '#....', '####.', '#....', '#....', '#....'],
    'G': ['.###.', '#...#', '#....', '#.###', '#...#', '#...#', '.####'],
    'H': ['#...#', '#...#', '#...#', '#####', '#...#', '#...#', '#...#'],
    'I': ['.###.', '..#..', '..#..', '..#..', '..#..', '..#..', '.###.'],
    'K': ['#...#', '#..#.', '#.#..', '##...', '#.#..', '#..#.', '#...#'],
    'L': ['#....', '#....', '#....', '#....', '#....', '#....', '#####'],
    'M': ['#...#', '##.##', '#.#.#', '#.#.#', '#...#', '#...#', '#...#'],
    'N': ['#...#', '##..#', '#.#.#', '#..##', '#...#', '#...#', '#...#'],
    'O': ['.###.', '#...#', '#...#', '#...#', '#...#', '#...#', '.###.'],
    'P': ['####.', '#...#', '#...#', '####.', '#....', '#....', '#....'],
    'R': ['####.', '#...#', '#...#', '####.', '#.#..', '#..#.', '#...#'],
    'S': ['.####', '#....', '#....', '.###.', '....#', '....#', '####.'],
    'T': ['#####', '..#..', '..#..', '..#..', '..#..', '..#..', '..#..'],
    'U': ['#...#', '#...#', '#...#', '#...#', '#...#', '#...#', '.###.'],
    'V': ['#...#', '#...#', '#...#', '#...#', '#...#', '.#.#.', '..#..'],
    'W': ['#...#', '#...#', '#...#', '#.#.#', '#.#.#', '##.##', '#...#'],
    'Y': ['#...#', '#...#', '.#.#.', '..#..', '..#..', '..#..', '..#..'],
    ' ': ['.....'] * 7,
}

# --- art.h ----------------------------------------------------------------------------------
out = ['// art.h - GENERATED by tools/menu_art.py: the menu\'s own tiles for osd.v. Do not edit.',
       '#pragma once', '#include <stdint.h>', '', 'namespace art {', '']
out.append('static const uint32_t SPLASH_PAL[8] = { %s };' % ', '.join('0x%06X' % v for v in SPLASH_PAL))
out.append('static const uint32_t MENU_PAL[8] = { %s };' % ', '.join('0x%06X' % v for v in MENU_PAL))
out.append('enum { C_WHITE, C_YELLOW, C_GREY, C_GREEN, C_PINK, C_RED, C_SKIN_OR_BLUE, C_BLACK };')
out.append('')
out.append('// glyph numbers')
out.append('enum : uint8_t { G_QUAD = 0x80, ' + ', '.join('G_%s = 0x%02X' % (n.upper(), 0x90 + i) for i, (n, _) in enumerate(ICONS))
           + ', G_LOGO = 0x%02X };' % LOGO_TILES)
out.append('')
out.append('// every glyph the menu loads: its number and 8 rows (bit 0 the leftmost pixel)')
out.append('struct Glyph { uint8_t code; uint8_t rows[8]; };')
glyphs = []
for q in range(16):        # quadrants: each 4 x 4 of the 8 x 8
    rows = []
    for y in range(8):
        r = 0
        if q & (1 if y < 4 else 4): r |= 0x0F
        if q & (2 if y < 4 else 8): r |= 0xF0
        rows.append(r)
    glyphs.append((0x80 + q, rows))
for i, (n, a) in enumerate(ICONS):
    glyphs.append((0x90 + i, bits(a)))
for i, rows in enumerate(tiles):
    glyphs.append((LOGO_TILES + i, rows))
out.append('static const Glyph GLYPHS[] = {')
for c, rows in glyphs:
    out.append('  { 0x%02X, { %s } },' % (c, ', '.join('0x%02X' % r for r in rows)))
out.append('};')
out.append('static const int NGLYPHS = %d;' % len(glyphs))
out.append('')
out.append('// the logo: %d x %d cells, each {glyph (0: none), ink, background}' % (W // 8, H // 8))
out.append('static const int LOGO_W = %d, LOGO_H = %d;' % (W // 8, H // 8))
out.append('struct LogoCell { uint8_t glyph, ink, bg; };')
out.append('static const LogoCell LOGO[] = {')
for g, ink, bg in cells:
    out.append('  { 0x%02X, %d, %d },' % (LOGO_TILES + g if g >= 0 else 0, ink, bg))
out.append('};')
out.append('')
out.append('// the big letters: 5 x 7, a row a byte (bit 4 the leftmost)')
out.append('struct BigChar { char c; uint8_t rows[7]; };')
out.append('static const BigChar BIG[] = {')
for ch, rows in FONT5.items():
    out.append("  { '%s', { %s } }," % (ch, ', '.join('0x%02X' % sum(1 << (4 - x) for x, v in enumerate(r) if v == '#') for r in rows)))
out.append('};')
out.append('static const int NBIG = %d;' % len(FONT5))
out.append('')
out.append('}  // namespace art')
out.append('')
open(os.path.join(root, 'esp32', 'console', 'art.h'), 'w', newline='\n').write('\n'.join(out))
print('art.h: %d glyphs (%d logo tiles), logo %dx%d cells' % (len(glyphs), len(tiles), W // 8, H // 8))
