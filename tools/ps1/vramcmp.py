"""vramcmp.py - ours | the console's | difference (red) for a ps1suite VRAM dump, half size.
    python tools/ps1/vramcmp.py NAME [x0 y0 x1 y1]   -> build/ps1suite/NAME_cmp.png"""
import os, sys
from PIL import Image, ImageChops
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ps1suite
name = sys.argv[1]
box = tuple(int(v) for v in sys.argv[2:6]) if len(sys.argv) >= 6 else (0, 0, 1024, 512)
ours = Image.open(os.path.join(ps1suite.OUT, name + '_vram.png')).convert('RGB')
refs = [r for n, l, v in ps1suite.tests() if n == name for r in v]
depth = '24bit' if '24bit' in name else '15bit' if '15bit' in name else ''
ref = Image.open(([r for r in refs if depth and depth in os.path.basename(r)] or refs)[0]).convert('RGB')
ref = ref.point(lambda c: c & 0xF8)
d = ImageChops.difference(ours, ref).convert('L').point(lambda c: 255 if c else 0)
diff = Image.merge('RGB', (d, Image.new('L', d.size), Image.new('L', d.size)))
w, h = box[2] - box[0], box[3] - box[1]
s = 1 if w <= 512 else 0.5
out = Image.new('RGB', (int(w * s) * 3 + 8, int(h * s)), (40, 40, 40))
for i, im in enumerate((ours, ref, diff)):
    out.paste(im.crop(box).resize((int(w * s), int(h * s)), Image.NEAREST), (i * (int(w * s) + 4), 0))
out.save(os.path.join(ps1suite.OUT, name + '_cmp.png'))
print(os.path.join(ps1suite.OUT, name + '_cmp.png'))
