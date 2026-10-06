"""ppu.py - the SNES picture chips (PPU1 + PPU2), as a model: their registers, the three memories
(VRAM, CGRAM, OAM) and a scanline renderer.

From Fullsnes (problemkaputt.de/fullsnes.htm) and the SNESdev wiki; checked against krom's PPU
test ROMs and their screenshots (tools/snes/snes.py --png). render_line(v) draws screen line v
(1..224 or 1..239) into self.frame with the registers as they are then, which is what a line
is drawn with on the console; the system calls it at the start of each line, after the
previous line's HDMA.

Pixels are 15-bit BGR (as CGRAM holds them); self.frame is 478 rows of 512: line v is rows
2(v-1) and 2(v-1)+1, or only the row of the current field when interlaced. Hi-res (modes 5 / 6)
and pseudo hi-res put the sub screen in the even columns and the main in the odd; otherwise
every pixel is doubled.
"""

# the layers' priority orders, front to back, per BG mode: ('B', bg, prio) or ('S', prio)
_ORDER = {
    0: [('S', 3), ('B', 0, 1), ('B', 1, 1), ('S', 2), ('B', 0, 0), ('B', 1, 0), ('S', 1),
        ('B', 2, 1), ('B', 3, 1), ('S', 0), ('B', 2, 0), ('B', 3, 0)],
    1: [('S', 3), ('B', 0, 1), ('B', 1, 1), ('S', 2), ('B', 0, 0), ('B', 1, 0), ('S', 1),
        ('B', 2, 1), ('S', 0), ('B', 2, 0)],
    '1+': [('B', 2, 1), ('S', 3), ('B', 0, 1), ('B', 1, 1), ('S', 2), ('B', 0, 0), ('B', 1, 0),
           ('S', 1), ('S', 0), ('B', 2, 0)],
    2: [('S', 3), ('B', 0, 1), ('S', 2), ('B', 1, 1), ('S', 1), ('B', 0, 0), ('S', 0), ('B', 1, 0)],
    6: [('S', 3), ('B', 0, 1), ('S', 2), ('S', 1), ('B', 0, 0), ('S', 0)],
    7: [('S', 3), ('S', 2), ('S', 1), ('B', 0, 0), ('S', 0)],
    '7+': [('S', 3), ('S', 2), ('B', 1, 1), ('S', 1), ('B', 0, 0), ('S', 0), ('B', 1, 0)],
}
for _m in (3, 4, 5):
    _ORDER[_m] = _ORDER[2]

# bits per pixel of BG1..BG4 per mode (0 = no such layer)
_BPP = {0: (2, 2, 2, 2), 1: (4, 4, 2, 0), 2: (4, 4, 0, 0), 3: (8, 4, 0, 0), 4: (8, 2, 0, 0),
        5: (4, 2, 0, 0), 6: (4, 0, 0, 0), 7: (8, 0, 0, 0)}

# OBJ sizes (small, large) as (w, h), by OBSEL bits 7-5
_OBJ_SIZES = [((8, 8), (16, 16)), ((8, 8), (32, 32)), ((8, 8), (64, 64)), ((16, 16), (32, 32)),
              ((16, 16), (64, 64)), ((32, 32), (64, 64)), ((16, 32), (32, 64)), ((16, 32), (32, 32))]


def _s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def _s13(v):
    v &= 0x1FFF
    return v - 0x2000 if v & 0x1000 else v


class PPU:
    def __init__(self):
        self.vram = [0] * 0x8000            # words
        self.cgram = [0] * 256
        self.oam = bytearray(544)
        self.frame = [[0] * 512 for _ in range(478)]  # (two rows a line: the fields)
        self.field = 0
        self.reset_regs()

    def reset_regs(self):
        self.inidisp = 0x80
        self.obsel = 0
        self.oamadd = 0                     # the word address as written
        self.oam_pri = False
        self.oam_addr = 0                   # the byte address the port uses
        self.oam_latch = 0
        self.bgmode = 0
        self.mosaic = 0
        self.bgsc = [0] * 4
        self.nba = [0] * 4
        self.hofs = [0] * 4
        self.vofs = [0] * 4
        self.ofs_latch = 0
        self.hofs_latch = 0
        self.m7_latch = 0
        self.vmain = 0
        self.vmadd = 0
        self.vram_read = 0
        self.m7sel = 0
        self.m7 = [0] * 6                   # A B C D X Y
        self.m7hofs = self.m7vofs = 0
        self.cgadd = 0
        self.cg_flip = False
        self.cg_latch = 0
        self.wsel = [0] * 3                 # W12SEL W34SEL WOBJSEL
        self.wpos = [0] * 4                 # WH0..WH3
        self.wbglog = self.wobjlog = 0
        self.tm = self.ts = self.tmw = self.tsw = 0
        self.cgwsel = self.cgadsub = 0
        self.fixed = 0                      # COLDATA as BGR555
        self.setini = 0
        self.mpy = 0
        self.stat77 = 0
        self.hlatch = self.vlatch = 0
        self.hl_flip = self.vl_flip = False
        self.mosaic_line = 1                # the line the vertical mosaic counts from
        self.ppu1_mdr = self.ppu2_mdr = 0

    # --- VRAM address remapping (VMAIN bits 3-2) ---------------------------------------------
    def vaddr(self):
        a = self.vmadd
        m = (self.vmain >> 2) & 3
        if m == 1:
            a = (a & 0xFF00) | ((a & 0x1F) << 3) | ((a >> 5) & 7)
        elif m == 2:
            a = (a & 0xFE00) | ((a & 0x3F) << 3) | ((a >> 6) & 7)
        elif m == 3:
            a = (a & 0xFC00) | ((a & 0x7F) << 3) | ((a >> 7) & 7)
        return a & 0x7FFF

    def vinc(self):
        self.vmadd = (self.vmadd + (1, 32, 128, 128)[self.vmain & 3]) & 0xFFFF

    # --- the CPU's side --------------------------------------------------------------------
    def write(self, r, v):
        """r = $2100-$213F"""
        if r == 0x2100:
            self.inidisp = v
        elif r == 0x2101:
            self.obsel = v
        elif r == 0x2102:
            self.oamadd = (self.oamadd & 0x100) | v
            self.oam_addr = (self.oamadd << 1) & 0x3FF
        elif r == 0x2103:
            self.oamadd = (self.oamadd & 0xFF) | ((v & 1) << 8)
            self.oam_pri = bool(v & 0x80)
            self.oam_addr = (self.oamadd << 1) & 0x3FF
        elif r == 0x2104:
            a = self.oam_addr
            if a >= 0x200:
                self.oam[0x200 | (a & 0x1F)] = v
            elif a & 1 == 0:
                self.oam_latch = v
            else:
                self.oam[a - 1] = self.oam_latch
                self.oam[a] = v
            self.oam_addr = (a + 1) & 0x3FF
        elif r == 0x2105:
            self.bgmode = v
        elif r == 0x2106:
            self.mosaic = v
        elif 0x2107 <= r <= 0x210A:
            self.bgsc[r - 0x2107] = v
        elif r == 0x210B:
            self.nba[0], self.nba[1] = v & 15, v >> 4
        elif r == 0x210C:
            self.nba[2], self.nba[3] = v & 15, v >> 4
        elif 0x210D <= r <= 0x2114:
            n = (r - 0x210D) >> 1
            if r & 1:                                   # HOFS ($210D $210F $2111 $2113)
                self.hofs[n] = ((v << 8) | (self.ofs_latch & ~7) | (self.hofs_latch & 7)) & 0x3FF
                self.hofs_latch = v
            else:
                self.vofs[n] = ((v << 8) | self.ofs_latch) & 0x3FF
            self.ofs_latch = v
            if r == 0x210D:
                self.m7hofs = _s13((v << 8) | self.m7_latch)
                self.m7_latch = v
            elif r == 0x210E:
                self.m7vofs = _s13((v << 8) | self.m7_latch)
                self.m7_latch = v
        elif r == 0x2115:
            self.vmain = v
        elif r == 0x2116:
            self.vmadd = (self.vmadd & 0xFF00) | v
            self.vram_read = self.vram[self.vaddr()]
        elif r == 0x2117:
            self.vmadd = (self.vmadd & 0xFF) | (v << 8)
            self.vram_read = self.vram[self.vaddr()]
        elif r == 0x2118:
            a = self.vaddr()
            self.vram[a] = (self.vram[a] & 0xFF00) | v
            if not self.vmain & 0x80:
                self.vinc()
        elif r == 0x2119:
            a = self.vaddr()
            self.vram[a] = (self.vram[a] & 0xFF) | (v << 8)
            if self.vmain & 0x80:
                self.vinc()
        elif r == 0x211A:
            self.m7sel = v
        elif 0x211B <= r <= 0x2120:
            self.m7[r - 0x211B] = (v << 8) | self.m7_latch
            self.m7_latch = v
            self.mpy = _s16(self.m7[0]) * (((self.m7[1] >> 8) ^ 0x80) - 0x80)
        elif r == 0x2121:
            self.cgadd = v
            self.cg_flip = False
        elif r == 0x2122:
            if not self.cg_flip:
                self.cg_latch = v
            else:
                self.cgram[self.cgadd] = ((v & 0x7F) << 8) | self.cg_latch
                self.cgadd = (self.cgadd + 1) & 0xFF
            self.cg_flip = not self.cg_flip
        elif 0x2123 <= r <= 0x2125:
            self.wsel[r - 0x2123] = v
        elif 0x2126 <= r <= 0x2129:
            self.wpos[r - 0x2126] = v
        elif r == 0x212A:
            self.wbglog = v
        elif r == 0x212B:
            self.wobjlog = v
        elif r == 0x212C:
            self.tm = v
        elif r == 0x212D:
            self.ts = v
        elif r == 0x212E:
            self.tmw = v
        elif r == 0x212F:
            self.tsw = v
        elif r == 0x2130:
            self.cgwsel = v
        elif r == 0x2131:
            self.cgadsub = v
        elif r == 0x2132:
            i = v & 0x1F
            if v & 0x20:
                self.fixed = (self.fixed & ~0x1F) | i
            if v & 0x40:
                self.fixed = (self.fixed & ~(0x1F << 5)) | (i << 5)
            if v & 0x80:
                self.fixed = (self.fixed & ~(0x1F << 10)) | (i << 10)
        elif r == 0x2133:
            self.setini = v

    def read(self, r, h=0, v=0):
        if r in (0x2134, 0x2135, 0x2136):
            m = self.mpy & 0xFFFFFF
            self.ppu1_mdr = (m >> (8 * (r - 0x2134))) & 0xFF
            return self.ppu1_mdr
        if r == 0x2137:                                 # latch the counters
            self.hlatch, self.vlatch = h, v
            self.stat78_latched = True
            return 0
        if r == 0x2138:
            a = self.oam_addr
            val = self.oam[0x200 | (a & 0x1F)] if a >= 0x200 else self.oam[a]
            self.oam_addr = (a + 1) & 0x3FF
            self.ppu1_mdr = val
            return val
        if r in (0x2139, 0x213A):
            val = self.vram_read & 0xFF if r == 0x2139 else self.vram_read >> 8
            if (r == 0x213A) == bool(self.vmain & 0x80):
                self.vram_read = self.vram[self.vaddr()]
                self.vinc()
            self.ppu1_mdr = val
            return val
        if r == 0x213B:
            c = self.cgram[self.cgadd]
            if not self.cg_flip:
                val = c & 0xFF
            else:
                val = (self.ppu2_mdr & 0x80) | (c >> 8)
                self.cgadd = (self.cgadd + 1) & 0xFF
            self.cg_flip = not self.cg_flip
            self.ppu2_mdr = val
            return val
        if r == 0x213C:
            val = (self.hlatch >> 8) & 1 if self.hl_flip else self.hlatch & 0xFF
            self.hl_flip = not self.hl_flip
            return val
        if r == 0x213D:
            val = (self.vlatch >> 8) & 1 if self.vl_flip else self.vlatch & 0xFF
            self.vl_flip = not self.vl_flip
            return val
        if r == 0x213E:
            return self.stat77 | 0x01
        if r == 0x213F:
            self.hl_flip = self.vl_flip = False
            return 0x03                                 # (PPU2 version 3, NTSC)
        return self.ppu1_mdr

    # --- drawing --------------------------------------------------------------------------
    def lines(self):
        return 239 if self.setini & 0x04 else 224

    def _tile_row(self, addr, bpp, row):
        """the 8 pixel indices of one tile row (addr = the tile's first word)"""
        w = self.vram
        p01 = w[(addr + row) & 0x7FFF]
        planes = [p01 & 0xFF, p01 >> 8]
        if bpp >= 4:
            p23 = w[(addr + 8 + row) & 0x7FFF]
            planes += [p23 & 0xFF, p23 >> 8]
        if bpp == 8:
            p45 = w[(addr + 16 + row) & 0x7FFF]
            p67 = w[(addr + 24 + row) & 0x7FFF]
            planes += [p45 & 0xFF, p45 >> 8, p67 & 0xFF, p67 >> 8]
        out = []
        for b in range(7, -1, -1):
            v = 0
            for i, pl in enumerate(planes):
                v |= ((pl >> b) & 1) << i
            out.append(v)
        return out

    def _bg_line(self, n, bpp, y, width, hires, ilace=False):
        """BG n's pixels on line y: lists (index, palette, priority) per x, x < width.
        Index 0 = transparent. ilace: hi-res interlace, 448 BG rows (2y + field)."""
        sc = self.bgsc[n]
        tm_base = (sc & 0xFC) << 8
        big = bool(self.bgmode & (0x10 << n))
        tw = 16 if (big or hires) else 8
        th = 16 if big else 8
        char_base = self.nba[n] << 12
        tile_words = 4 * bpp
        mode = self.bgmode & 7
        mos = (self.mosaic >> 4) + 1 if self.mosaic & (1 << n) else 1
        if mos > 1:
            y = y - (y - self.mosaic_line) % mos if y >= self.mosaic_line else y
        if ilace:
            y = 2 * y + self.field
        mos_x = mos                                   # (in hi-res too: blocks of `mos` of the 512)
        hofs, vofs = self.hofs[n], self.vofs[n]
        opt = mode in (2, 4, 6) and n < 2
        out = [None] * width
        cache = {}
        rows = {}
        step = 2 if hires else 1                        # (hi-res: 512 pixels, the scroll is in 256ths)
        for x in range(width):
            sx = x - x % mos_x if mos > 1 else x
            ho, vo = hofs, vofs
            if opt:
                ho, vo = self._opt(n, sx // step if hires else sx, ho, vo)
            px = (sx + ho * step) if hires else (sx + ho)
            py = y + vo
            tx, ty = px // tw, py // th
            key = (tx, ty)
            ent = cache.get(key)
            if ent is None:
                mx, my = tx & 63, ty & 63
                a = tm_base + ((my & 31) << 5) + (mx & 31)
                if mx & 32 and sc & 1:
                    a += 0x400
                if my & 32 and sc & 2:
                    a += 0x800 if sc & 1 else 0x400
                ent = self.vram[a & 0x7FFF]
                cache[key] = ent
            ch = ent & 0x3FF
            pal = (ent >> 10) & 7
            pri = (ent >> 13) & 1
            fx, fy = px % tw, py % th
            if ent & 0x4000:
                fx = tw - 1 - fx
            if ent & 0x8000:
                fy = th - 1 - fy
            if tw == 16 and fx >= 8:
                ch += 1
            if th == 16 and fy >= 8:
                ch += 16
            ch &= 0x3FF
            rkey = (ch, fy & 7)
            row = rows.get(rkey)
            if row is None:
                row = self._tile_row(char_base + ch * tile_words, bpp, fy & 7)
                rows[rkey] = row
            out[x] = (row[fx & 7], pal, pri)
        return out

    def _opt(self, n, x, ho, vo):
        """offset-per-tile (modes 2, 4, 6): BG3's tilemap gives BG1 / BG2 their scroll per
        column, from the second column on"""
        mode = self.bgmode & 7
        col = (x + (ho & 7)) >> 3
        if col == 0:
            return ho, vo
        h3, v3 = self.hofs[2], self.vofs[2]
        sc = self.bgsc[2]
        base = (sc & 0xFC) << 8
        tx = ((col - 1) * 8 + (h3 & ~7)) >> 3
        ty = v3 >> 3

        def ent_at(tx, ty):
            mx, my = tx & 63, ty & 63
            a = base + ((my & 31) << 5) + (mx & 31)
            if mx & 32 and sc & 1:
                a += 0x400
            if my & 32 and sc & 2:
                a += 0x800 if sc & 1 else 0x400
            return self.vram[a & 0x7FFF]
        bit = 0x2000 << n
        if mode == 4:
            e = ent_at(tx, ty)
            if e & bit:
                if e & 0x8000:
                    vo = e & 0x3FF
                else:
                    ho = (e & 0x3F8) | (ho & 7)
        else:
            eh = ent_at(tx, ty)
            ev = ent_at(tx, ty + 1)
            if eh & bit:
                ho = (eh & 0x3F8) | (ho & 7)
            if ev & bit:
                vo = ev & 0x3FF
        return ho, vo

    def _m7_line(self, y):
        """mode 7: (pixel, ) per x for 256 x; pixel = the 8-bit value, None = transparent"""
        a, b, c, d = (_s16(v) for v in self.m7[:4])
        x0, y0 = _s13(self.m7[4]), _s13(self.m7[5])
        hof, vof = self.m7hofs, self.m7vofs
        sel = self.m7sel
        mos = (self.mosaic >> 4) + 1 if self.mosaic & 1 else 1
        if mos > 1 and y >= self.mosaic_line:
            y = y - (y - self.mosaic_line) % mos
        sy = 255 - y if sel & 2 else y

        def clip(v):
            return (v | ~0x3FF) if v & 0x2000 else (v & 0x3FF)
        ch = clip(hof - x0)
        cv = clip(vof - y0)
        bx = ((a * ch) & ~63) + ((b * cv) & ~63) + ((b * sy) & ~63) + (x0 << 8)
        by = ((c * ch) & ~63) + ((d * cv) & ~63) + ((d * sy) & ~63) + (y0 << 8)
        out = [None] * 256
        for x in range(256):
            sx = x - x % mos if mos > 1 else x
            if sel & 1:
                sx = 255 - sx
            X = (bx + a * sx) >> 8
            Y = (by + c * sx) >> 8
            over = (X | Y) & ~0x3FF
            if over and (sel >> 6) == 2:
                continue
            if over and (sel >> 6) == 3:
                tile = 0
            else:
                tile = self.vram[((Y >> 3) & 127) * 128 + ((X >> 3) & 127)] & 0xFF
            out[x] = self.vram[(tile * 64 + (Y & 7) * 8 + (X & 7)) & 0x7FFF] >> 8
        return out

    def _obj_line(self, v):
        """the sprites on line v: a list of 256 (color index, priority) or None; sets the
        range / time over flags"""
        small, large = _OBJ_SIZES[self.obsel >> 5]
        base = (self.obsel & 7) << 13
        gap = (((self.obsel >> 3) & 3) + 1) << 12
        first = (self.oamadd >> 1) & 0x7F if self.oam_pri else 0
        inter = bool(self.setini & 0x02)
        found = []
        for k in range(128):
            i = (first + k) & 0x7F
            o = self.oam[i * 4:i * 4 + 4]
            hi = (self.oam[0x200 + (i >> 2)] >> ((i & 3) * 2)) & 3
            w, h = large if hi & 2 else small
            x = o[0] | ((hi & 1) << 8)
            if x >= 256:
                x -= 512
            yy = o[1]
            # (a sprite shows one line below its Y: its first row is on line Y + 1)
            dy = (v - 1 - yy) & 0xFF
            if inter:                               # (OBJ interlace: every other row, by field)
                if dy >= h // 2:
                    continue
                dy = dy * 2 + self.field
            if dy >= h:
                continue
            if x <= -w or x >= 256:
                if x != -256:
                    continue
            if len(found) == 32:
                self.stat77 |= 0x40                     # range over
                break
            found.append((i, x, dy, w, h, o))
        out = [None] * 256
        tiles = 0
        slivers = []
        for (i, x, dy, w, h, o) in reversed(found):
            attr = o[3]
            row = h - 1 - dy if attr & 0x80 else dy
            for tc in range(w // 8):
                sx = x + tc * 8
                if sx <= -8 or sx >= 256:
                    continue
                tiles += 1
                if tiles > 34:
                    self.stat77 |= 0x80                 # time over
                    break
                slivers.append((i, sx, tc, row, w, attr, o))
            if tiles > 34:
                break
        # draw: lower OAM index (from the first) in front
        order = {i: n for n, (i, *_r) in enumerate(found)}
        for (i, sx, tc, row, w, attr, o) in sorted(slivers, key=lambda s: -order[s[0]]):
            col = (w // 8 - 1 - tc) if attr & 0x40 else tc
            name = o[2] | ((attr & 1) << 8)
            r_ = ((name >> 4) + (row >> 3)) & 15
            c_ = ((name & 15) + col) & 15
            addr = base + ((r_ << 4 | c_) << 4) + (gap if name & 0x100 else 0)
            pix = self._tile_row(addr & 0x7FFF, 4, row & 7)
            if attr & 0x40:
                pix = pix[::-1]
            pal = (attr >> 1) & 7
            pri = (attr >> 4) & 3
            for k, p in enumerate(pix):
                x = sx + k
                if 0 <= x < 256 and p:
                    out[x] = (128 + pal * 16 + p, pri)
        return out

    def _window(self, sel4, log2, x):
        """sel4 = the layer's 4 window-select bits, log2 = its 2 logic bits; True = inside"""
        w1 = w2 = None
        if sel4 & 2:
            w1 = self.wpos[0] <= x <= self.wpos[1]
            if sel4 & 1:
                w1 = not w1
        if sel4 & 8:
            w2 = self.wpos[2] <= x <= self.wpos[3]
            if sel4 & 4:
                w2 = not w2
        if w1 is None and w2 is None:
            return False
        if w1 is None:
            return w2
        if w2 is None:
            return w1
        return (w1 or w2, w1 and w2, w1 != w2, w1 == w2)[log2]

    def render_line(self, v):
        if v < 1 or v > self.lines():
            return
        inter = bool(self.setini & 1)
        rows = [2 * (v - 1) + self.field] if inter else [2 * (v - 1), 2 * (v - 1) + 1]
        out = [0] * 512
        if self.inidisp & 0x80:
            for r in rows:
                self.frame[r] = out
            return
        mode = self.bgmode & 7
        hires = mode in (5, 6)
        width = 512 if hires else 256
        bpps = _BPP[mode]
        extbg = mode == 7 and bool(self.setini & 0x40)
        if mode == 1 and self.bgmode & 8:
            order = _ORDER['1+']
        elif extbg:
            order = _ORDER['7+']
        else:
            order = _ORDER[mode]
        used = self.tm | self.ts
        layers = {}
        if mode == 7:
            if used & 1 or (extbg and used & 2):
                m7 = self._m7_line(v)
                layers[0] = [None if p is None else (p, 0, 0) for p in m7]
                if extbg:
                    layers[1] = [None if p is None else (p & 0x7F, 0, p >> 7) for p in m7]
        else:
            for n in range(4):
                if bpps[n] and used & (1 << n):
                    layers[n] = self._bg_line(n, bpps[n], v, width, hires, hires and inter)
        obj = self._obj_line(v) if used & 0x10 else [None] * 256

        direct = bool(self.cgwsel & 1) and mode in (3, 4, 7)
        sel = [self.wsel[0] & 15, self.wsel[0] >> 4, self.wsel[1] & 15, self.wsel[1] >> 4, self.wsel[2] & 15]
        logs = [self.wbglog & 3, (self.wbglog >> 2) & 3, (self.wbglog >> 4) & 3, (self.wbglog >> 6) & 3, self.wobjlog & 3]

        def color_of(n, p, pal):
            bpp = bpps[n] if mode != 7 else (7 if n == 1 else 8)
            if bpp == 8 and direct:
                r = ((p & 7) << 2) | ((pal & 1) << 1)
                g = (((p >> 3) & 7) << 2) | (pal & 2)
                b = (((p >> 6) & 3) << 3) | ((pal & 4))
                return r | (g << 5) | (b << 10)
            if mode == 7:
                return self.cgram[p]
            if bpp == 2:
                return self.cgram[(n * 32 if mode == 0 else 0) + pal * 4 + p]
            if bpp == 4:
                return self.cgram[pal * 16 + p]
            return self.cgram[p]

        def pick(x, xo, enable, wmask):
            """the front pixel of the layers in `enable` at layer column x (screen column xo):
            (color, layer: 0-3 BG, 4 OBJ, 5 backdrop, OBJ palette 4-7)"""
            for ent in order:
                if ent[0] == 'S':
                    if not enable & 0x10:
                        continue
                    o = obj[xo]
                    if o is None or o[1] != ent[1]:
                        continue
                    if wmask & 0x10 and self._window(sel[4], logs[4], xo):
                        continue
                    return self.cgram[o[0]], 4, o[0] >= 192
                _, n, pr = ent
                if not enable & (1 << n) or n not in layers:
                    continue
                px = layers[n][x]
                if px is None or px[0] == 0 or px[2] != pr:
                    continue
                if wmask & (1 << n) and self._window(sel[n], logs[n], xo):
                    continue
                return color_of(n, px[0], px[1]), n, False
            return None, 5, False

        cw_sel, cw_log = self.wsel[2] >> 4, (self.wobjlog >> 2) & 3
        bright = self.inidisp & 15
        half = bool(self.cgadsub & 0x40)
        sub_mode = bool(self.cgwsel & 2)
        pseudo = bool(self.setini & 0x08) and not hires
        split = hires or pseudo
        black = (self.cgwsel >> 6) & 3
        prevent = (self.cgwsel >> 4) & 3
        prev = None                                     # (the main pixel to the left, for hi-res)
        for xo in range(256):
            xm, xs = (2 * xo + 1, 2 * xo) if hires else (xo, xo)
            mc, ml, mobj = pick(xm, xo, self.tm, self.tmw)
            if mc is None:
                mc = self.cgram[0]
            if sub_mode or split:
                sc, _, _ = pick(xs, xo, self.ts, self.tsw)
            else:
                sc = None
            sub_backdrop = sc is None
            if sc is None:
                sc = self.fixed
            cw = self._window(cw_sel, cw_log, xo)
            clip = black == 3 or (black == 1 and not cw) or (black == 2 and cw)
            noblend = prevent == 3 or (prevent == 1 and not cw) or (prevent == 2 and cw)
            if clip:
                mc = 0
            raw = mc
            math_on = bool(self.cgadsub & (1 << ml)) if ml < 4 else (
                bool(self.cgadsub & 0x10) and mobj if ml == 4 else bool(self.cgadsub & 0x20))
            if math_on and not noblend:
                other = sc if (sub_mode and not sub_backdrop) else self.fixed
                h = half and not clip and not (sub_mode and sub_backdrop)
                mc = _blend(mc, other, bool(self.cgadsub & 0x80), h)
            m = _bright(mc, bright)
            if split:
                # (even columns: the sub screen, odd: the main. The sub pixel goes through the
                # colour math too, against the main pixel to its left: the chip makes the even
                # half-dot before the odd one, with the previous dot's main pixel still held)
                sp = sc if not sub_backdrop else self.cgram[0]
                if prev is not None and prev[1]:
                    sp = _blend(sp, prev[0] if sub_mode else self.fixed, bool(self.cgadsub & 0x80), half)
                out[2 * xo] = _bright(sp, bright)
                out[2 * xo + 1] = m
                prev = (raw, math_on and not noblend)
            else:
                out[2 * xo] = out[2 * xo + 1] = m
        for r in rows:
            self.frame[r] = out


def _blend(a, b, sub, half):
    out = 0
    for sh in (0, 5, 10):
        ca, cb = (a >> sh) & 31, (b >> sh) & 31
        if sub:
            c = ca - cb
            if half:
                c >>= 1
            c = max(c, 0)
        else:
            c = ca + cb
            if half:
                c >>= 1
            c = min(c, 31)
        out |= c << sh
    return out


def _bright(c, b):
    if b == 15:
        return c
    out = 0
    for sh in (0, 5, 10):
        out |= (((c >> sh) & 31) * (b + 1) >> 4) << sh
    return out
