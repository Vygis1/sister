"""texcache_model.py - ps1_raster's texture cache, modelled, against a real game's drawing lists.

Replays GP0 packets (a JSON of draw lists, e.g. captured from DuckStation's RAM at GsDrawOt) the
way ps1_raster walks them -- each textured primitive's bounding box row by row, a pixel PAIR at a
time -- works out every texel's VRAM line (16 bytes) and runs those through a cache model:

  sets x ways of 16-byte lines, indexed {texture row bits, line-column bits} as ps1_raster's
  tidx() (TROWB rows, TCOLB columns), LRU within a set; a miss fetches a tile of lines
  (ps1_cache's read-around: TW lines wide by TH rows) and every line of it is filled.

    python tools/ps1/texcache_model.py build/syphon_drawlists.json

Counts misses (a DDR3 round trip each, the pipeline stopped) per textured pixel for each
configuration. A yardstick for choosing the cache, not a picture: the edge rules are close, not
exact, and the video cache between the texture cache and DDR3 is not modelled.
"""
import json
import sys
from collections import OrderedDict


def s11(v):
    v &= 0x7FF
    return v - 0x800 if v & 0x400 else v


class Cache:
    def __init__(self, trowb, tcolb, ways, tw, th):
        self.trowb, self.tcolb, self.ways, self.tw, self.th = trowb, tcolb, ways, tw, th
        self.sets = [OrderedDict() for _ in range(1 << (trowb + tcolb))]
        self.miss = self.access = 0

    def idx(self, line):                     # line = byte address >> 4; row = line >> 7
        row, col = line >> 7, line & 127
        return ((row & ((1 << self.trowb) - 1)) << self.tcolb) | (col & ((1 << self.tcolb) - 1))

    def _fill(self, line):
        s = self.sets[self.idx(line)]
        if line in s:
            s.move_to_end(line)
            return
        if len(s) >= self.ways:
            s.popitem(last=False)
        s[line] = True

    def touch(self, lines):
        """a pixel pair: both lines must be in hand"""
        for line in lines:
            self.access += 1
            s = self.sets[self.idx(line)]
            if line in s:
                s.move_to_end(line)
                continue
            self.miss += 1
            row, col = line >> 7, line & 127
            c0, r0 = col - col % self.tw, row - row % self.th
            for dr in range(self.th):
                for dc in range(self.tw):
                    self._fill(((r0 + dr) & 511) << 7 | ((c0 + dc) & 127))
            self._fill(line)


class Gpu:
    def __init__(self, caches):
        self.caches = caches
        self.tpx = self.tpy = self.depth = 0
        self.win = (0, 0, 0, 0)
        self.area = (0, 0, 1023, 511)
        self.ofs = (0, 0)
        self.pixels = 0

    def texel_line(self, u, v, tpx, tpy, depth):
        mx, my, ox, oy = self.win
        u &= 255; v &= 255
        u = (u & ~(mx * 8)) | ((ox & mx) * 8)
        v = (v & ~(my * 8)) | ((oy & my) * 8)
        x = tpx * 64 + (u >> 2 if depth == 0 else u >> 1 if depth == 1 else u)
        y = (tpy * 256 + v) & 511
        return (y * 2048 + (x & 1023) * 2) >> 4

    def draw(self, pts, uvs, tpage):
        tpx, tpy, depth = tpage & 15, (tpage >> 4) & 1, (tpage >> 7) & 3
        if depth == 3:
            depth = 2
        x0a, y0a, x1a, y1a = self.area
        ox, oy = self.ofs
        P = [(x + ox, y + oy) for x, y in pts]
        xs = [p[0] for p in P]; ys = [p[1] for p in P]
        bx0, bx1 = max(min(xs), x0a), min(max(xs), x1a)
        by0, by1 = max(min(ys), y0a), min(max(ys), y1a)
        if bx0 > bx1 or by0 > by1 or max(xs) - min(xs) > 1023 or max(ys) - min(ys) > 511:
            return
        (ax, ay), (bx, by), (cx, cy) = P
        area = (bx - ax) * (cy - ay) - (cx - ax) * (by - ay)
        if area == 0:
            return
        (u0, v0), (u1, v1), (u2, v2) = uvs
        for y in range(by0, by1 + 1):
            pairs = []
            for x in range(bx0 & ~1, bx1 + 1, 2):
                pair = []
                for xx in (x, x + 1):
                    if xx < bx0 or xx > bx1:
                        continue
                    w0 = (bx - xx) * (cy - y) - (cx - xx) * (by - y)
                    w1 = (cx - xx) * (ay - y) - (ax - xx) * (cy - y)
                    w2 = (ax - xx) * (by - y) - (bx - xx) * (ay - y)
                    if area > 0 and (w0 < 0 or w1 < 0 or w2 < 0):
                        continue
                    if area < 0 and (w0 > 0 or w1 > 0 or w2 > 0):
                        continue
                    u = int((w0 * u0 + w1 * u1 + w2 * u2) / area)
                    v = int((w0 * v0 + w1 * v1 + w2 * v2) / area)
                    pair.append(self.texel_line(u, v, tpx, tpy, depth))
                if pair:
                    self.pixels += len(pair)
                    for c in self.caches:
                        c.touch(pair)

    def rect(self, x, y, w, h, u, v, tpage):
        tpx, tpy, depth = tpage & 15, (tpage >> 4) & 1, (tpage >> 7) & 3
        x0a, y0a, x1a, y1a = self.area
        x += self.ofs[0]; y += self.ofs[1]
        for yy in range(max(y, y0a), min(y + h - 1, y1a) + 1):
            for xx in range(max(x, x0a) & ~1, min(x + w - 1, x1a) + 1, 2):
                pair = [self.texel_line(u + (px - x), v + (yy - y), tpx, tpy, depth)
                        for px in (xx, xx + 1) if max(x, x0a) <= px <= min(x + w - 1, x1a)]
                if pair:
                    self.pixels += len(pair)
                    for c in self.caches:
                        c.touch(pair)

    def packet(self, ws):
        i = 0
        while i < len(ws):
            w = ws[i]; op = w >> 24
            if op == 0xE1:
                self.tpage_e1 = w & 0x3FF; i += 1
            elif op == 0xE2:
                self.win = (w & 31, (w >> 5) & 31, (w >> 10) & 31, (w >> 15) & 31); i += 1
            elif op == 0xE3:
                self.area = (w & 1023, (w >> 10) & 511, self.area[2], self.area[3]); i += 1
            elif op == 0xE4:
                self.area = (self.area[0], self.area[1], w & 1023, (w >> 10) & 511); i += 1
            elif op == 0xE5:
                self.ofs = (s11(w), s11(w >> 11)); i += 1
            elif 0x20 <= op <= 0x3F:
                gour, quad, tex = op & 0x10, op & 0x08, op & 0x04
                nv = 4 if quad else 3
                per = 1 + (1 if tex else 0) + (1 if gour else 0)
                n = 1 + nv * per - (1 if gour else 0)
                pk = ws[i:i + n]
                if len(pk) < n:
                    return
                pts, uvs, tpage, k = [], [], 0, 1
                for vi in range(nv):
                    if gour and vi > 0:
                        k += 1
                    xy = pk[k]; k += 1
                    pts.append((s11(xy), s11(xy >> 16)))
                    if tex:
                        uv = pk[k]; k += 1
                        uvs.append((uv & 255, (uv >> 8) & 255))
                        if vi == 1:
                            tpage = uv >> 16
                if tex:
                    self.draw(pts[:3], uvs[:3], tpage)
                    if quad:
                        self.draw(pts[1:4], uvs[1:4], tpage)
                i += n
            elif 0x60 <= op <= 0x7F:
                tex, sz = op & 0x04, (op >> 3) & 3
                n = 2 + (1 if tex else 0) + (1 if sz == 0 else 0)
                pk = ws[i:i + n]
                if len(pk) < n:
                    return
                xy = pk[1]
                k = 2
                u = v = 0
                if tex:
                    u, v = pk[2] & 255, (pk[2] >> 8) & 255; k = 3
                if sz == 0:
                    w_, h_ = pk[k] & 0xFFFF, pk[k] >> 16
                else:
                    w_ = h_ = {1: 1, 2: 8, 3: 16}[sz]
                if tex:
                    self.rect(s11(xy), s11(xy >> 16), w_, h_, u, v, getattr(self, 'tpage_e1', 0))
                i += n
            elif 0x40 <= op <= 0x5F:
                i = len(ws)                       # lines: no texture
            elif op == 0x02:
                i += 3
            elif op in (0x80, 0xA0, 0xC0):
                i = len(ws)
            else:
                i += 1


CONFIGS = [
    # name, TROWB, TCOLB, ways, tile w (lines), tile h (rows)
    ('now: 4 KB direct, 64x4, tile 2x2', 6, 2, 1, 2, 2),
    ('4 KB 2-way, 32x4 sets', 5, 2, 2, 2, 2),
    ('4 KB 4-way, 16x4 sets', 4, 2, 4, 2, 2),
    ('8 KB direct, 64x8', 6, 3, 1, 2, 2),
    ('8 KB 2-way, 64x4 sets', 6, 2, 2, 2, 2),
    ('16 KB direct, 64x16', 6, 4, 1, 2, 2),
    ('16 KB 4-way, 64x4 sets', 6, 2, 4, 2, 2),
    ('4 KB direct, tile 4x2', 6, 2, 1, 4, 2),
    ('4 KB direct, tile 2x4', 6, 2, 1, 2, 4),
    ('8 KB 2-way, tile 2x4', 6, 2, 2, 2, 4),
]


def main():
    lists = json.load(open(sys.argv[1]))
    caches = [Cache(*c[1:]) for c in CONFIGS]
    g = Gpu(caches)
    for fr in lists:
        for pk in fr['packets']:
            g.packet(pk)
    print('%d textured pixels' % g.pixels)
    base = caches[0].miss
    for (name, *_), c in zip(CONFIGS, caches):
        print('  %-36s misses %7d  (%.3f a pixel, %5.1f%% of now)' % (name, c.miss, c.miss / max(1, g.pixels), 100.0 * c.miss / max(1, base)))


if __name__ == '__main__':
    main()
