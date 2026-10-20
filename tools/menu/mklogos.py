"""mklogos.py - the graphical menu's console logos and controller drawings, for the SD card.

They are the consoles' makers' trademarks, so they are not in this repository: this fetches
RetroPie's "carbon" theme art (github.com/RetroPie/es-theme-carbon, <system>/art/system.svg and
controller.svg), renders it (PyMuPDF) and writes what the ESP32 reads from /menu/logos/:

    python tools/menu/mklogos.py              -> build/menu_logos/<key>_logo.lgo, <key>_pad.lgo;
                                                 build/menu_icons/<button>.lgo (-> /menu/icons)
    python tools/sdput.py build/menu_logos/nes_logo.lgo /menu/logos/nes_logo.lgo   (each)

.lgo: "LGO1", width and height (16-bit little-endian), then width x height pixels of
R, G, B, A (8 bits each). Logos fit 92 x 34 (the console tiles) -- 160 x 48 for the larger
copies (_big) --, controllers 78 x 42, all cropped to what they draw.
"""
import io
import os
import re
import struct
import sys
import urllib.request

import pymupdf
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, 'build', 'menu_logos')
CACHE = os.path.join(ROOT, 'build', 'menu_art')
BASE = 'https://raw.githubusercontent.com/RetroPie/es-theme-carbon/master/%s/art/%s.svg'
# the menu's key (MACHINES[].core in menu.h) -> carbon's folder
SYSTEMS = {'nes': 'nes', 'sms': 'mastersystem', 'md': 'megadrive', 'ps1': 'psx', 'n64': 'n64', 'snes': 'snes',
           'gg': 'gamegear', 'gb': 'gb', 'a26': 'atari2600', 'pce': 'pcengine', 'gba': 'gba', 'pc': 'pc'}


def fetch(folder, name):
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, '%s_%s.svg' % (folder, name))
    if not os.path.exists(path):
        try:
            data = urllib.request.urlopen(BASE % (folder, name), timeout=30).read()
        except Exception as e:
            print('  %s/%s: %s' % (folder, name, e))
            return None
        open(path, 'wb').write(data)
    return open(path, 'rb').read()


def solid_gradients(svg):
    """gradient fills as their middle stop's colour (MuPDF draws some referenced gradients black)"""
    text = svg.decode('utf-8', 'replace')
    stops = {}
    for m in re.finditer(r'<linearGradient[^>]*id="([^"]+)"(.*?)</linearGradient>', text, re.S):
        cols = re.findall(r'stop-color:(#[0-9A-Fa-f]{6})', m.group(2))
        if cols:
            stops[m.group(1)] = cols[len(cols) // 2]
    text = re.sub(r'fill="url\(#([^)]+)\)"', lambda m: 'fill="%s"' % stops.get(m.group(1), '#C8D0E0'), text)
    return text.encode('utf-8')


def render(svg, max_w, max_h):
    doc = pymupdf.open(stream=svg, filetype='svg')
    page = doc[0]
    zoom = 4 * max_h / page.rect.height                 # (big, then down: smoother edges)
    pix = page.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom), alpha=True)
    im = Image.open(io.BytesIO(pix.tobytes('png'))).convert('RGBA')
    box = im.getbbox()
    if box:
        im = im.crop(box)
    im.thumbnail((max_w, max_h), Image.LANCZOS)
    return im


def write(im, path):
    with open(path, 'wb') as f:
        f.write(b'LGO1' + struct.pack('<HH', im.width, im.height) + im.tobytes())


def icons():
    """the pad's buttons and the gear, drawn here (4x, then down: smooth edges) -> build/menu_icons"""
    import math
    from PIL import ImageDraw
    out = os.path.join(ROOT, 'build', 'menu_icons')
    os.makedirs(out, exist_ok=True)
    S = 4

    def canvas(w, h):
        im = Image.new('RGBA', (w * S, h * S), (0, 0, 0, 0))
        return im, ImageDraw.Draw(im)

    def done(im, w, h, name):
        write(im.resize((w, h), Image.LANCZOS), os.path.join(out, name + '.lgo'))

    c = 10 * S
    im, d = canvas(20, 20)
    d.line((c - 4 * S, c - 4 * S, c + 4 * S, c + 4 * S), fill=(150, 170, 255, 255), width=2 * S)
    d.line((c - 4 * S, c + 4 * S, c + 4 * S, c - 4 * S), fill=(150, 170, 255, 255), width=2 * S)
    done(im, 20, 20, 'cross')
    im, d = canvas(20, 20)
    d.ellipse((c - 5 * S, c - 5 * S, c + 5 * S, c + 5 * S), outline=(255, 120, 130, 255), width=2 * S)
    done(im, 20, 20, 'circle')
    im, d = canvas(20, 20)
    d.rectangle((c - 4 * S, c - 4 * S, c + 4 * S, c + 4 * S), outline=(240, 140, 210, 255), width=int(1.8 * S))
    done(im, 20, 20, 'square')
    im, d = canvas(20, 20)
    d.polygon([(c, c - 5 * S), (c + 5 * S, c + 4 * S), (c - 5 * S, c + 4 * S)], outline=(110, 220, 170, 255), width=int(1.8 * S))
    done(im, 20, 20, 'triangle')
    im, d = canvas(20, 20)
    d.rounded_rectangle((c - 7 * S, c - 4 * S, c + 7 * S, c + 4 * S), radius=3 * S, outline=(220, 222, 240, 255), width=S)
    done(im, 20, 20, 'start')
    im, d = canvas(20, 20)
    from PIL import ImageFont
    f = ImageFont.truetype(os.path.join(ROOT, 'tools', 'menu', 'fonts', 'Nunito.ttf'), 11 * S)
    f.set_variation_by_axes([800])
    d.text((c, c), 'L1', font=f, fill=(220, 222, 240, 255), anchor='mm')
    done(im, 20, 20, 'l1')
    im, d = canvas(24, 24)
    g = 12 * S
    for i in range(8):
        a = i * math.pi / 4
        d.line((g + math.cos(a) * 6 * S, g + math.sin(a) * 6 * S, g + math.cos(a) * 11 * S, g + math.sin(a) * 11 * S),
               fill=(200, 205, 230, 255), width=5 * S)
    d.ellipse((g - 8 * S, g - 8 * S, g + 8 * S, g + 8 * S), fill=(200, 205, 230, 255))
    d.ellipse((g - 3 * S, g - 3 * S, g + 3 * S, g + 3 * S), fill=(0, 0, 0, 0))
    done(im, 24, 24, 'gear')
    print('icons: %s' % out)


def main():
    icons()
    os.makedirs(OUT, exist_ok=True)
    for key, folder in SYSTEMS.items():
        logo = fetch(folder, 'system')
        if logo:
            if key == 'md':
                logo = solid_gradients(logo)
            write(render(logo, 92, 34), os.path.join(OUT, key + '_logo.lgo'))
            big = render(logo, 160, 48)
            write(big, os.path.join(OUT, key + '_big.lgo'))
            big.save(os.path.join(OUT, key + '_big.png'))     # (to look at)
        pad = fetch(folder, 'controller')
        if pad:
            im = render(pad, 78, 42)
            # thin grey lines in the theme: darkened for the menu's light tiles
            r, g, b, a = im.split()
            im = Image.merge('RGBA', tuple(c.point(lambda v: v // 3) for c in (r, g, b)) + (a,))
            write(im, os.path.join(OUT, key + '_pad.lgo'))
        print('%-4s %s%s' % (key, 'logo ' if logo else '', 'controller' if pad else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())
