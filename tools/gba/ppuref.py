"""A reference rendering of the Game Boy Advance's picture from the bench's dump, against ours.
    python tools/gba/ppuref.py build/sim-gba-x [build/ref.png] [build/diff.png]

Reads vram.hex, pram.hex, oam.hex and regs.txt (tb_gba's dump at the end of a run) and draws the
frame the way GBATEK describes it -- the four backgrounds in the mode's shapes, the sprites,
windows, blending -- then compares it with frame.ppm, pixel for pixel, and says where they differ.
The point is to find which part of gba_ppu is wrong, so the rendering is plain and slow.
"""
import sys
from PIL import Image

W, H = 240, 160


def load(d):
    vram = bytearray()
    for l in open(d + '/vram.hex'):
        w = int(l, 16); vram += bytes([w & 255, (w >> 8) & 255, (w >> 16) & 255, w >> 24])
    pram = [int(l, 16) for l in open(d + '/pram.hex')]
    oam = []
    for l in open(d + '/oam.hex'):
        w = int(l, 16); oam += [w & 0xFFFF, w >> 16]
    regs = {}
    for l in open(d + '/regs.txt'):
        t = l.replace('mosaic', '').split(); regs[t[0]] = [int(x, 16) for x in t[1:]]
    return bytes(vram), pram, oam, regs


def rgb(c):
    return ((c & 31) << 3 | (c & 31) >> 2, ((c >> 5) & 31) << 3 | ((c >> 5) & 31) >> 2, ((c >> 10) & 31) << 3 | ((c >> 10) & 31) >> 2)


def text_bg(vram, cnt, hofs, vofs, y):
    """one line of a text background: palette indices (0 = transparent), 240 wide"""
    cbb = ((cnt >> 2) & 3) * 0x4000
    sbb = ((cnt >> 8) & 31) * 0x800
    bpp8 = cnt & 0x80
    size = (cnt >> 14) & 3
    tw = 512 if size & 1 else 256
    th = 512 if size & 2 else 256
    out = []
    ty = (y + vofs) % th
    for x in range(W):
        tx = (x + hofs) % tw
        sb = sbb + (0x800 if tx >= 256 and size & 1 else 0) + ((0x1000 if size == 3 else 0x800) if ty >= 256 and size & 2 else 0)
        e = sb + ((ty & 255) // 8) * 64 + ((tx & 255) // 8) * 2
        ent = vram[e] | vram[e + 1] << 8
        tile = ent & 0x3FF; hf = ent & 0x400; vf = ent & 0x800; pal = ent >> 12
        px = tx & 7; py = ty & 7
        if hf: px = 7 - px
        if vf: py = 7 - py
        if bpp8:
            a = cbb + tile * 64 + py * 8 + px
            idx = vram[a] if a < len(vram) else 0
        else:
            a = cbb + tile * 32 + py * 4 + px // 2
            b = vram[a] if a < len(vram) else 0
            idx = (b >> 4) if px & 1 else (b & 15)
            if idx: idx |= pal << 4
        out.append(idx)
    return out


def affine_bg(vram, cnt, pa, pb, pc, pd, x0, y0, y, bitmap_mode, frame):
    """one line of an affine background or bitmap: (direct colour, index) pairs"""
    def s16(v): return v - 0x10000 if v & 0x8000 else v
    def s28(v): return v - 0x10000000 if v & 0x8000000 else v
    pa, pb, pc, pd = s16(pa), s16(pb), s16(pc), s16(pd)
    cx = s28(x0) + pb * y; cy = s28(y0) + pd * y
    out = []
    cbb = ((cnt >> 2) & 3) * 0x4000
    sbb = ((cnt >> 8) & 31) * 0x800
    size = 128 << ((cnt >> 14) & 3)
    wrap = cnt & 0x2000
    for x in range(W):
        tx = (cx + pa * x) >> 8; ty = (cy + pc * x) >> 8
        if bitmap_mode:
            if bitmap_mode == 3:
                if 0 <= tx < 240 and 0 <= ty < 160:
                    a = (ty * 240 + tx) * 2; out.append((True, vram[a] | vram[a + 1] << 8))
                else: out.append((False, 0))
            elif bitmap_mode == 4:
                if 0 <= tx < 240 and 0 <= ty < 160:
                    out.append((False, vram[(0xA000 if frame else 0) + ty * 240 + tx]))
                else: out.append((False, 0))
            else:
                if 0 <= tx < 160 and 0 <= ty < 128:
                    a = (0xA000 if frame else 0) + (ty * 160 + tx) * 2; out.append((True, vram[a] | vram[a + 1] << 8))
                else: out.append((False, 0))
            continue
        if wrap:
            tx %= size; ty %= size
        elif not (0 <= tx < size and 0 <= ty < size):
            out.append((False, 0)); continue
        tile = vram[sbb + (ty // 8) * (size // 8) + tx // 8]
        out.append((False, vram[cbb + tile * 64 + (ty & 7) * 8 + (tx & 7)]))
    return out


SIZES = {(0, 0): (8, 8), (0, 1): (16, 16), (0, 2): (32, 32), (0, 3): (64, 64),
         (1, 0): (16, 8), (1, 1): (32, 8), (1, 2): (32, 16), (1, 3): (64, 32),
         (2, 0): (8, 16), (2, 1): (8, 32), (2, 2): (16, 32), (2, 3): (32, 64)}


def sprites(vram, oam, dispcnt, y, bitmap):
    """one line of sprites: (index, prio, mode) per pixel, first sprite wins; the window mask"""
    out = [None] * W; win = [False] * W
    map1d = dispcnt & 0x40
    def s16(v): return v - 0x10000 if v & 0x8000 else v
    for i in range(128):
        a0, a1, a2 = oam[i * 4], oam[i * 4 + 1], oam[i * 4 + 2]
        aff = a0 & 0x100
        if not aff and a0 & 0x200: continue
        shape = a0 >> 14
        if shape == 3: continue
        w, h = SIZES[(shape, a1 >> 14)]
        bw, bh = (w * 2, h * 2) if (aff and a0 & 0x200) else (w, h)
        sy = a0 & 255; sx = a1 & 511
        if sx >= 256: sx -= 512
        dy = (y - sy) & 255
        if dy >= bh: continue
        mode = (a0 >> 10) & 3
        if mode == 3: continue
        bpp8 = a0 & 0x2000; hf = a1 & 0x1000; vf = a1 & 0x2000
        tile = a2 & 0x3FF; prio = (a2 >> 10) & 3; pal = a2 >> 12
        if aff:
            g = (a1 >> 9) & 31
            pa, pb, pc, pd = (s16(oam[g * 16 + 3]), s16(oam[g * 16 + 7]), s16(oam[g * 16 + 11]), s16(oam[g * 16 + 15]))
        for bx in range(bw):
            x = sx + bx
            if not (0 <= x < W): continue
            if aff:
                rx = bx - bw // 2; ry = dy - bh // 2
                tx = ((pa * rx + pb * ry) >> 8) + w // 2
                ty = ((pc * rx + pd * ry) >> 8) + h // 2
                if not (0 <= tx < w and 0 <= ty < h): continue
            else:
                tx = (w - 1 - bx) if hf else bx
                ty = (h - 1 - dy) if vf else dy
            if bpp8:
                tn = tile + (ty // 8) * ((w // 8) * 2 if map1d else 32) + (tx // 8) * 2
                if bitmap and tn < 512: continue
                idx = vram[0x10000 + (tn // 2) * 64 + (ty & 7) * 8 + (tx & 7)]
            else:
                tn = tile + (ty // 8) * (w // 8 if map1d else 32) + tx // 8
                if bitmap and tn < 512: continue
                b = vram[0x10000 + tn * 32 + (ty & 7) * 4 + (tx & 7) // 2]
                idx = (b >> 4) if tx & 1 else (b & 15)
                if idx: idx |= pal << 4
            if not idx: continue
            if mode == 2: win[x] = True
            elif out[x] is None: out[x] = (idx, prio, mode)
    return out, win


def render(vram, pram, oam, regs):
    dispcnt = regs['dispcnt'][0]
    mode = dispcnt & 7
    img = Image.new('RGB', (W, H))
    bgcnt = [regs['bg%d' % k][0] for k in range(4)]
    hofs = [regs['bg%d' % k][1] for k in range(4)]
    vofs = [regs['bg%d' % k][2] for k in range(4)]
    aff = {k: regs['aff%d' % k] for k in (2, 3)}
    win0h, win1h, win0v, win1v, winin, winout = regs['win']
    bldcnt, bldalpha, bldy = regs['bld'][:3]
    for y in range(H):
        lines = {}
        if mode <= 1:
            for k in (0, 1):
                if dispcnt & (0x100 << k): lines[k] = [(False, v) for v in text_bg(vram, bgcnt[k], hofs[k], vofs[k], y)]
        if mode == 0:
            for k in (2, 3):
                if dispcnt & (0x100 << k): lines[k] = [(False, v) for v in text_bg(vram, bgcnt[k], hofs[k], vofs[k], y)]
        if mode == 1 and dispcnt & 0x400:
            lines[2] = affine_bg(vram, bgcnt[2], *aff[2], y, 0, 0)
        if mode == 2:
            for k in (2, 3):
                if dispcnt & (0x100 << k): lines[k] = affine_bg(vram, bgcnt[k], *aff[k], y, 0, 0)
        if mode >= 3 and dispcnt & 0x400:
            lines[2] = affine_bg(vram, bgcnt[2], *aff[2], y, mode, dispcnt & 0x10)
        objl, objwin = sprites(vram, oam, dispcnt, y, mode >= 3) if dispcnt & 0x1000 else ([None] * W, [False] * W)
        w0y = (win0v >> 8) <= y < (win0v & 255) if (win0v >> 8) <= (win0v & 255) else (y >= (win0v >> 8) or y < (win0v & 255))
        w1y = (win1v >> 8) <= y < (win1v & 255) if (win1v >> 8) <= (win1v & 255) else (y >= (win1v >> 8) or y < (win1v & 255))
        for x in range(W):
            # the window
            if dispcnt & 0xE000:
                in0 = dispcnt & 0x2000 and w0y and ((win0h >> 8) <= x < (win0h & 255) if (win0h >> 8) <= (win0h & 255) else (x >= (win0h >> 8) or x < (win0h & 255)))
                in1 = dispcnt & 0x4000 and w1y and ((win1h >> 8) <= x < (win1h & 255) if (win1h >> 8) <= (win1h & 255) else (x >= (win1h >> 8) or x < (win1h & 255)))
                if in0: mask = winin & 0x3F
                elif in1: mask = (winin >> 8) & 0x3F
                elif dispcnt & 0x8000 and objwin[x]: mask = (winout >> 8) & 0x3F
                else: mask = winout & 0x3F
            else: mask = 0x3F
            # the layers in priority order
            cands = []
            if mask & 16 and objl[x] is not None:
                cands.append((objl[x][1], -1, 4, (False, objl[x][0])))
            for k in range(4):
                if mask & (1 << k) and k in lines and lines[k][x][1] != 0:
                    cands.append((bgcnt[k] & 3, k, k, lines[k][x]))
            cands.sort(key=lambda c: (c[0], c[1]))
            cands.append((4, 9, 5, (False, 0))); cands.append((4, 9, 5, (False, 0)))
            top = cands[0]; sec = cands[1]
            def colour(c):
                if c[2] == 5: return pram[0]
                if c[3][0]: return c[3][1]
                return pram[(256 if c[2] == 4 else 0) + c[3][1]]
            c1 = colour(top); c2 = colour(sec)
            semi = top[2] == 4 and objl[x][2] == 1
            eff = (bldcnt >> 6) & 3
            t1 = bldcnt & (1 << top[2]); t2 = bldcnt & (1 << (8 + sec[2]))
            o = c1
            if dispcnt & 0x80: o = 0x7FFF
            elif mask & 32 or semi:
                eva, evb, evy = bldalpha & 31, (bldalpha >> 8) & 31, bldy & 31
                if (semi and t2) or (eff == 1 and t1 and t2):
                    o = 0
                    for sh in (0, 5, 10):
                        v = min(31, (((c1 >> sh) & 31) * eva + ((c2 >> sh) & 31) * evb) >> 4); o |= v << sh
                elif mask & 32 and eff in (2, 3) and t1:
                    o = 0
                    for sh in (0, 5, 10):
                        a = (c1 >> sh) & 31
                        v = a + (((31 - a) * evy) >> 4) if eff == 2 else a - ((a * evy) >> 4); o |= v << sh
            img.putpixel((x, y), rgb(o))
    return img


def main():
    d = sys.argv[1]
    vram, pram, oam, regs = load(d)
    ref = render(vram, pram, oam, regs)
    ref.save(sys.argv[2] if len(sys.argv) > 2 else d + '/ref.png')
    toks = open(d + '/frame.ppm', 'rb').read().split()
    vals = [0 if b'x' in t else int(t) for t in toks[4:4 + W * H * 3]]
    bad = 0; rows = {}
    diff = Image.new('RGB', (W, H))
    for y in range(H):
        for x in range(W):
            ours = tuple(vals[(y * W + x) * 3:(y * W + x) * 3 + 3])
            r = ref.getpixel((x, y))
            same = ours == r
            if not same:
                bad += 1; rows[y] = rows.get(y, 0) + 1
            diff.putpixel((x, y), (255, 0, 0) if not same else tuple(c // 2 + 64 for c in r))
    print('%d of %d pixels differ' % (bad, W * H))
    if bad:
        worst = sorted(rows.items(), key=lambda kv: -kv[1])[:5]
        print('  worst rows: ' + ', '.join('y=%d (%d)' % kv for kv in worst))
    if len(sys.argv) > 3:
        diff.save(sys.argv[3])
    sys.exit(0 if bad == 0 else 1)


if __name__ == '__main__':
    main()
