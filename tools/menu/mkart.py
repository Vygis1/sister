"""mkart.py - the graphical menu's console art, drawn here: no outside artwork.

Each machine gets a name plate (its name set in the menu's own typeface, in its colour) and a
line drawing of its controller or handheld, drawn from simple shapes at 8x and scaled down so
the edges are smooth. The files are what the ESP32 reads from the card (/menu/logos), under
the names the firmware already uses, so nothing on the board side changes:

    python tools/menu/mkart.py          -> build/menu_logos/<key>_logo.lgo   (92 x 34 at most)
                                                            <key>_big.lgo    (160 x 48 at most)
                                                            <key>_pad.lgo    (78 x 42 at most)
                                           build/menu_icons/<button>.lgo      (-> /menu/icons)
                                           build/menu_logos/sheet.png         (all of it, to look at)
                                           esp32/console/gfx_art.h            (the same, built in)

The firmware carries the logos, drawings and icons itself (gfx_art.h): nothing has to be put on
the card. A file of the same name on the card (/menu/logos, /menu/icons) is drawn instead:

    python tools/sdput.py build/menu_logos/nes_logo.lgo /menu/logos/nes_logo.lgo   (each)

.lgo: "LGO1", width and height (16-bit little-endian), then width x height pixels of
R, G, B, A (8 bits each).

(Until 2026-11 the logos and controllers were RetroPie's "carbon" theme art, fetched and
rendered by tools/menu/mklogos.py. The makers' logos are their trademarks and the drawings
were someone else's work; a name in plain type is only a name.)
"""
import math
import os
import struct
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, 'build', 'menu_logos')
ICONS = os.path.join(ROOT, 'build', 'menu_icons')
TTF = os.path.join(ROOT, 'tools', 'menu', 'fonts', 'Nunito.ttf')
S = 8                                    # drawn at 8x, then scaled down
BIG_SHARE = 0.66                         # the big line's part of a two-line plate's height

# the menu's key -> (the small line, the big line, its colour: menu.h MCOL)
MACHINES = {
    'nes':  ('',          'NES',     (215, 55, 60)),
    'sms':  ('MASTER',    'SYSTEM',  (210, 60, 70)),
    'md':   ('MEGA',      'DRIVE',   (50, 120, 220)),
    'n64':  ('NINTENDO',  '64',      (40, 160, 90)),
    'ps1':  ('PLAY',      'STATION', (150, 155, 180)),
    'snes': ('SUPER',     'NES',     (125, 100, 210)),
    'gg':   ('GAME',      'GEAR',    (90, 90, 110)),
    'gb':   ('GAME',      'BOY',     (130, 175, 50)),
    'a26':  ('ATARI',     '2600',    (200, 120, 60)),
    'pce':  ('PC',        'ENGINE',  (235, 135, 35)),
    'gba':  ('GAME BOY',  'ADVANCE', (80, 100, 235)),
    'pc':   ('DOS',       'PC',      (120, 130, 150)),
}
INK = (64, 70, 98, 255)                  # the drawings' lines: dark on the light tiles
FILL = (204, 209, 224, 255)              # a screen, a D-pad
SOFT = (238, 240, 246, 255)              # a body's face


def font(px, weight):
    f = ImageFont.truetype(TTF, px)
    f.set_variation_by_axes([weight])
    return f


def write(im, path):
    with open(path, 'wb') as f:
        f.write(b'LGO1' + struct.pack('<HH', im.width, im.height) + im.convert('RGBA').tobytes())


def shrink(im, max_w, max_h):
    box = im.getbbox()
    if box:
        im = im.crop(box)
    k = min(max_w / im.width, max_h / im.height)
    return im.resize((max(1, round(im.width * k)), max(1, round(im.height * k))), Image.LANCZOS)


def deepen(c, k=0.78):
    """the colour darker, the more so the lighter it is: the light tiles need the contrast"""
    lum = (0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]) / 255
    k = min(k, 0.62 / max(lum, 0.01)) if lum > 0.45 else k
    return tuple(int(v * k) for v in c)


# --- the name plates ---------------------------------------------------------------------------------
def plate(small, big, colour, max_w, max_h):
    """two lines: a small spaced line over a heavy one, both in the machine's colour"""
    ink = deepen(colour) + (255,)
    fb = font(40 * S // 4, 950)
    fs = font(15 * S // 4, 800)
    track = 2 * S // 4                   # the small line's letter spacing

    def width(f, t, tr=0):
        return sum(f.getlength(ch) for ch in t) + tr * max(0, len(t) - 1)

    wb = width(fb, big)
    ws = width(fs, small, track) if small else 0
    w = int(max(wb, ws)) + 8 * S
    h = 80 * S // 4
    im = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    y = 0
    if small:
        x = (w - ws) / 2
        for ch in small:
            d.text((x, y), ch, font=fs, fill=ink)
            x += fs.getlength(ch) + track
        y += 15 * S // 4
    d.text(((w - wb) / 2, y - 2 * S // 4), big, font=fb, fill=ink)
    # a two-line plate fills max_h; a one-line plate's big line comes out the size it has in a
    # two-line one (BIG_SHARE of the height), so a short name is not blown up
    im = im.crop(im.getbbox())
    hh = im.height / (1.0 if small else BIG_SHARE)
    k = min(max_w / im.width, max_h / hh)
    return im.resize((max(1, round(im.width * k)), max(1, round(im.height * k))), Image.LANCZOS)


# --- the drawings ---------------------------------------------------------------------------------------
class Pen:
    """shapes in the drawing's own units (the 78 x 42 box), drawn at S times that"""
    def __init__(self, w=78, h=42):
        self.im = Image.new('RGBA', (w * S, h * S), (0, 0, 0, 0))
        self.d = ImageDraw.Draw(self.im)
        self.lw = int(1.6 * S)

    def p(self, *xy):
        return [v * S for v in xy]

    def rrect(self, x, y, w, h, r, fill=SOFT, line=True):
        self.d.rounded_rectangle(self.p(x, y, x + w, y + h), radius=r * S, fill=fill, outline=INK if line else None,
                                 width=self.lw if line else 0)

    def ellipse(self, cx, cy, rx, ry, fill=SOFT, line=True):
        self.d.ellipse(self.p(cx - rx, cy - ry, cx + rx, cy + ry), fill=fill, outline=INK if line else None,
                       width=self.lw if line else 0)

    def dot(self, cx, cy, r, fill=INK):
        self.d.ellipse(self.p(cx - r, cy - r, cx + r, cy + r), fill=fill)

    def ring(self, cx, cy, r):
        self.ellipse(cx, cy, r, r, fill=FILL)

    def poly(self, pts, fill=SOFT, line=True):
        q = [(x * S, y * S) for x, y in pts]
        self.d.polygon(q, fill=fill)
        if line:
            self.d.line(q + [q[0]], fill=INK, width=self.lw, joint='curve')

    def line(self, *xy, w=1.6):
        self.d.line(self.p(*xy), fill=INK, width=int(w * S))

    def dpad(self, cx, cy, r, arm=None):
        arm = arm or r * 0.38
        self.poly([(cx - arm, cy - r), (cx + arm, cy - r), (cx + arm, cy - arm), (cx + r, cy - arm), (cx + r, cy + arm),
                   (cx + arm, cy + arm), (cx + arm, cy + r), (cx - arm, cy + r), (cx - arm, cy + arm), (cx - r, cy + arm),
                   (cx - r, cy - arm), (cx - arm, cy - arm)], fill=FILL)

    def pill(self, cx, cy, w, h, angle=0):
        """a small rounded bar (select / start), turned by angle degrees"""
        a = math.radians(angle)
        dx, dy = math.cos(a) * (w - h) / 2, math.sin(a) * (w - h) / 2
        self.d.line(self.p(cx - dx, cy - dy, cx + dx, cy + dy), fill=INK, width=int(h * S))
        for sx in (-1, 1):
            self.dot(cx + sx * dx, cy + sx * dy, h / 2)

    def blob(self, pts, fill=SOFT):
        """a smooth closed outline through the points (Catmull-Rom), for bodies that are not boxes"""
        out = []
        n = len(pts)
        for i in range(n):
            p0, p1, p2, p3 = pts[i - 1], pts[i], pts[(i + 1) % n], pts[(i + 2) % n]
            for k in range(12):
                t = k / 12
                t2, t3 = t * t, t * t * t
                out.append(tuple(0.5 * ((2 * p1[j]) + (-p0[j] + p2[j]) * t + (2 * p0[j] - 5 * p1[j] + 4 * p2[j] - p3[j]) * t2 +
                                        (-p0[j] + 3 * p1[j] - 3 * p2[j] + p3[j]) * t3) for j in (0, 1)))
        self.poly(out, fill=fill)


def draw_nes():
    g = Pen()
    g.rrect(4, 9, 70, 26, 2.5)
    g.rrect(8, 13, 62, 18, 1.5, fill=(222, 225, 236, 255))
    g.dpad(17, 22, 6.5)
    g.pill(33, 25, 6, 2.4); g.pill(41, 25, 6, 2.4)
    for x in (54, 64):
        g.ring(x, 23, 4)
    return g.im


def draw_snes():
    g = Pen()
    g.blob([(14, 9), (64, 9), (75, 21), (64, 34), (50, 32), (28, 32), (14, 34), (3, 21)])
    g.dpad(15, 21, 6)
    g.pill(33, 22, 5.5, 2.2, -30); g.pill(42, 22, 5.5, 2.2, -30)
    for x, y in ((63, 15), (69, 21), (57, 21), (63, 27)):
        g.ring(x, y, 3.2)
    return g.im


def draw_n64():
    g = Pen()
    g.blob([(8, 8), (39, 6), (70, 8), (76, 16), (66, 26), (60, 39), (52, 37), (46, 25), (39, 38), (32, 25), (26, 37),
            (18, 39), (12, 26), (2, 16)])
    g.dpad(14, 16, 5)
    g.ring(39, 21, 4.2)
    g.dot(39, 21, 1.6)
    for x, y in ((64, 12), (70, 17), (58, 17), (64, 22)):
        g.dot(x, y, 2.1, fill=FILL); g.ellipse(x, y, 2.1, 2.1, fill=FILL)
    g.ring(53, 21, 2.8); g.ring(50, 14, 2.8)
    g.dot(39, 12, 1.8)
    return g.im


def draw_gb():
    g = Pen(42, 42)
    g.d.rounded_rectangle(g.p(9, 1, 33, 41), radius=2 * S, fill=SOFT, outline=INK, width=g.lw)
    g.rrect(12, 4, 18, 15, 1.2, fill=(222, 225, 236, 255))
    g.rrect(15, 6, 12, 10, 0.6, fill=FILL)
    g.dpad(16, 26, 3.6)
    g.ring(26, 28, 1.9); g.ring(30, 25, 1.9)
    g.pill(19, 35, 3.2, 1.4, -30); g.pill(24, 35, 3.2, 1.4, -30)
    return g.im


def draw_gba():
    g = Pen()
    g.blob([(10, 7), (68, 7), (76, 15), (74, 33), (64, 37), (14, 37), (4, 33), (2, 15)])
    g.rrect(24, 10, 30, 22, 2, fill=(222, 225, 236, 255))
    g.rrect(28, 13, 22, 16, 0.8, fill=FILL)
    g.dpad(13, 20, 4.6)
    g.ring(65, 18, 2.6); g.ring(70, 23, 2.6)
    g.dot(13, 31, 1.1); g.dot(17, 31, 1.1)
    return g.im


def draw_sms():
    g = Pen()
    g.rrect(4, 10, 70, 24, 3)
    g.dpad(18, 22, 6.8, 2.6)
    g.ring(18, 22, 2)
    for x in (52, 63):
        g.ring(x, 23, 4)
    g.dot(36, 17, 1); g.dot(40, 17, 1)
    return g.im


def draw_md():
    g = Pen()
    g.blob([(12, 9), (39, 6), (66, 9), (76, 20), (67, 34), (52, 31), (39, 33), (26, 31), (11, 34), (2, 20)])
    g.ellipse(16, 20, 8, 8, fill=FILL)
    g.dpad(16, 20, 6, 2.1)
    g.pill(39, 14, 5, 2.1)
    for i, x in enumerate((52, 60, 68)):
        g.ring(x, 24 - i * 3, 3.2)
    return g.im


def draw_gg():
    g = Pen()
    g.blob([(14, 7), (64, 7), (76, 16), (76, 28), (64, 37), (14, 37), (2, 28), (2, 16)])
    g.rrect(23, 10, 32, 24, 2.5, fill=(222, 225, 236, 255))
    g.rrect(27, 13, 24, 18, 1, fill=FILL)
    g.ellipse(12, 22, 6, 6, fill=FILL)
    g.dpad(12, 22, 4.4, 1.6)
    g.ring(64, 24, 2.8); g.ring(70, 19, 2.8)
    g.dot(66, 12, 1.1)
    return g.im


def draw_pce():
    g = Pen()
    g.blob([(6, 11), (72, 11), (75, 22), (68, 33), (10, 33), (3, 22)])
    g.dpad(17, 22, 6.2)
    g.pill(34, 25, 5, 2.1); g.pill(43, 25, 5, 2.1)
    g.ring(56, 24, 3.8); g.ring(66, 24, 3.8)
    g.line(30, 15, 48, 15, w=1)
    return g.im


def draw_ps1():
    g = Pen()
    g.blob([(14, 8), (64, 8), (74, 16), (77, 36), (68, 39), (58, 27), (39, 26), (20, 27), (10, 39), (1, 36), (4, 16)])
    g.ellipse(15, 18, 7.4, 7.4, fill=FILL, line=False)
    g.dpad(15, 18, 6, 2.1)
    for x, y in ((63, 12), (69, 18), (57, 18), (63, 24)):
        g.ellipse(x, y, 2.7, 2.7, fill=FILL)
    g.pill(34, 18, 4.5, 1.8); g.pill(44, 18, 4.5, 1.8)
    return g.im


def draw_a26():
    g = Pen(42, 42)
    g.rrect(6, 18, 30, 22, 3)
    g.line(21, 29, 21, 6, w=3.2)
    g.ellipse(21, 6, 3.4, 3.4, fill=INK, line=False)
    g.ellipse(21, 29, 5, 3.4, fill=FILL)
    g.ellipse(11, 22, 2.6, 2.6, fill=(200, 80, 70, 255))
    return g.im


def draw_pc():
    g = Pen()
    g.rrect(18, 2, 42, 28, 2)
    g.rrect(21, 5, 36, 21, 1, fill=FILL)
    for i, t in enumerate(('C:\\>_',)):
        pass
    g.line(24, 10, 32, 10, w=1.2); g.line(24, 14, 38, 14, w=1.2); g.line(24, 18, 28, 18, w=1.2)
    g.rrect(34, 30, 10, 3, 0.5, fill=FILL)
    g.poly([(10, 34), (68, 34), (74, 41), (4, 41)], fill=SOFT)
    for r in range(2):
        for k in range(10):
            g.line(12 + k * 5.4 + r * 1.5, 36.5 + r * 2.2, 14.5 + k * 5.4 + r * 1.5, 36.5 + r * 2.2, w=1.1)
    return g.im


DRAW = {'nes': draw_nes, 'snes': draw_snes, 'n64': draw_n64, 'gb': draw_gb, 'gba': draw_gba, 'sms': draw_sms,
        'md': draw_md, 'gg': draw_gg, 'pce': draw_pce, 'ps1': draw_ps1, 'a26': draw_a26, 'pc': draw_pc}


# --- the pad's buttons and the gear --------------------------------------------------------------------
def icons():
    os.makedirs(ICONS, exist_ok=True)
    T = 4

    def canvas(w, h):
        im = Image.new('RGBA', (w * T, h * T), (0, 0, 0, 0))
        return im, ImageDraw.Draw(im)

    def done(im, w, h, name):
        small = im.resize((w, h), Image.LANCZOS)
        write(small, os.path.join(ICONS, name + '.lgo'))
        BUILTIN.append(('/menu/icons/%s.lgo' % name, small))

    c = 10 * T
    im, d = canvas(20, 20)
    d.line((c - 4 * T, c - 4 * T, c + 4 * T, c + 4 * T), fill=(150, 170, 255, 255), width=2 * T)
    d.line((c - 4 * T, c + 4 * T, c + 4 * T, c - 4 * T), fill=(150, 170, 255, 255), width=2 * T)
    done(im, 20, 20, 'cross')
    im, d = canvas(20, 20)
    d.ellipse((c - 5 * T, c - 5 * T, c + 5 * T, c + 5 * T), outline=(255, 120, 130, 255), width=2 * T)
    done(im, 20, 20, 'circle')
    im, d = canvas(20, 20)
    d.rectangle((c - 4 * T, c - 4 * T, c + 4 * T, c + 4 * T), outline=(240, 140, 210, 255), width=int(1.8 * T))
    done(im, 20, 20, 'square')
    im, d = canvas(20, 20)
    d.polygon([(c, c - 5 * T), (c + 5 * T, c + 4 * T), (c - 5 * T, c + 4 * T)], outline=(110, 220, 170, 255), width=int(1.8 * T))
    done(im, 20, 20, 'triangle')
    im, d = canvas(20, 20)
    d.rounded_rectangle((c - 7 * T, c - 4 * T, c + 7 * T, c + 4 * T), radius=3 * T, outline=(220, 222, 240, 255), width=T)
    done(im, 20, 20, 'start')
    im, d = canvas(20, 20)
    f = font(11 * T, 800)
    d.text((c, c), 'L1', font=f, fill=(220, 222, 240, 255), anchor='mm')
    done(im, 20, 20, 'l1')
    im, d = canvas(24, 24)
    g = 12 * T
    for i in range(8):
        a = i * math.pi / 4
        d.line((g + math.cos(a) * 6 * T, g + math.sin(a) * 6 * T, g + math.cos(a) * 11 * T, g + math.sin(a) * 11 * T),
               fill=(200, 205, 230, 255), width=5 * T)
    d.ellipse((g - 8 * T, g - 8 * T, g + 8 * T, g + 8 * T), fill=(200, 205, 230, 255))
    d.ellipse((g - 3 * T, g - 3 * T, g + 3 * T, g + 3 * T), fill=(0, 0, 0, 0))
    done(im, 24, 24, 'gear')


BUILTIN = []                             # (card path, image) for gfx_art.h


def header(path):
    """every image as RGBA bytes in the firmware, found by the path it would have on the card"""
    out = ['// gfx_art.h - GENERATED by tools/menu/mkart.py: the console art and button icons of the menu,',
           '// built in (a file of the same name on the card is drawn instead: gfx.h loadImage). Do not edit.',
           '#pragma once', '#include <stdint.h>', '', 'namespace gfxart {',
           'struct Pic { const char *path; uint16_t w, h; const uint8_t *px; };']
    names = []
    for i, (card, im) in enumerate(BUILTIN):
        data = im.convert('RGBA').tobytes()
        out.append('static const uint8_t P%d[%d] = {' % (i, len(data)))
        for k in range(0, len(data), 32):
            out.append('  ' + ','.join(str(b) for b in data[k:k + 32]) + ',')
        out.append('};')
        names.append('  { "%s", %d, %d, P%d },' % (card, im.width, im.height, i))
    out.append('static const Pic PICS[] = {')
    out += names
    out.append('};')
    out.append('static const int NPICS = %d;' % len(BUILTIN))
    out.append('}  // namespace gfxart')
    nl = chr(10)
    with open(path, 'w', newline=nl) as f:
        f.write(nl.join(out) + nl)


def main():
    icons()
    os.makedirs(OUT, exist_ok=True)
    sheet = Image.new('RGBA', (6 * 130, 2 * 150), (24, 26, 48, 255))
    for i, (key, (small, big, colour)) in enumerate(MACHINES.items()):
        logo = plate(small, big, colour, 92, 34)
        write(logo, os.path.join(OUT, key + '_logo.lgo'))
        BUILTIN.append(('/menu/logos/%s_logo.lgo' % key, logo))
        bigp = plate(small, big, colour, 160, 48)
        write(bigp, os.path.join(OUT, key + '_big.lgo'))
        pad = shrink(DRAW[key](), 78, 42)
        write(pad, os.path.join(OUT, key + '_pad.lgo'))
        BUILTIN.append(('/menu/logos/%s_pad.lgo' % key, pad))
        # the sheet: each as it sits on its tile (108 x 128, the logo at y 26, the drawing at y 68)
        x0, y0 = (i % 6) * 130 + 11, (i // 6) * 150 + 11
        tile = Image.new('RGBA', (108, 128), (0, 0, 0, 0))
        ImageDraw.Draw(tile).rounded_rectangle((0, 0, 107, 127), radius=14, fill=(226, 229, 238, 255))
        ImageDraw.Draw(tile).rounded_rectangle((0, 98, 107, 127), radius=14, fill=colour + (255,))
        ImageDraw.Draw(tile).rectangle((0, 98, 107, 112), fill=colour + (255,))
        tile.alpha_composite(logo, (54 - logo.width // 2, 26 - logo.height // 2))
        tile.alpha_composite(pad, (54 - pad.width // 2, 68 - pad.height // 2))
        sheet.alpha_composite(tile, (x0, y0))
    sheet.save(os.path.join(OUT, 'sheet.png'))
    header(os.path.join(ROOT, 'esp32', 'console', 'gfx_art.h'))
    print('%d machines -> %s, icons -> %s' % (len(MACHINES), OUT, ICONS))
    return 0


if __name__ == '__main__':
    sys.exit(main())
