"""vidref.py - the reference for n64_vid's picture filters, and the gate for sim/tb_n64_vid.v.

    python tools/vidref.py gen CASE      writes sim/vid/{img,cfg}.hex for the bench
    python tools/vidref.py check CASE    compares build/sim-tb_n64_vid/out.hex with the model
    python tools/vidref.py all           every case: gen, bench, check
    python tools/vidref.py show CASE     the model's picture as build/vid_CASE.png (to look at)

The source pictures are made to look like a 3D console's: shaded triangles over a
gradient, dithered to 5 bits with the N64's magic square, partial coverage on the
triangles' edges; the model below does what the RTL does, integer for integer.
"""
import os
import random
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VD = os.path.join(ROOT, 'sim', 'vid')

# name: (PS1, width, height, bpp32, hid_ok, opt, vist)
CASES = {
    'n64_game':   (0, 320, 240, 0, 0, 0x0000, 0x0311E | (1 << 16)),   # SM64's VI: AA, divot, gamma... + dedither
    'n64_hid':    (0, 320, 240, 0, 1, 0x0000, 0x0311E | (1 << 16)),   # with the hidden coverage bits
    'n64_off':    (0, 320, 240, 0, 1, 0x0011 | 0x80, 0x0311E),        # VI filters off, sharp, no gamma
    'n64_smooth': (0, 320, 240, 0, 1, 0x0026, 0x0311E),               # all filters, smooth both ways, heavy... light scanlines
    'n64_edge':   (0, 320, 240, 0, 1, 0x000B | 0x80, 0x0311E | (1 << 16)),  # edge-directed, heavy scanlines
    'n64_32':     (0, 320, 240, 1, 0, 0x0000, 0x03113),               # 32-bit frame
    'n64_hi':     (0, 640, 480, 0, 1, 0x0000, 0x0311E | (1 << 16)),   # 640 wide: 1:1
    'ps1':        (1, 320, 240, 0, 0, 0x0000, 0),
    'ps1_dd':     (1, 256, 224, 0, 0, 0x0043, 0),                     # 256 wide (centred), dedither, edge
    'ps1_smooth': (1, 320, 240, 0, 0, 0x0042 | 0x4, 0),               # smooth + light scanlines
}

H_TOT, V_TOT = 800, 525


def isqrt_round(n):
    s = 0
    while (s + 1) * (s + 1) <= n:
        s += 1
    if s * s + s < n:
        s += 1
    return min(s, 255)


GAM = [isqrt_round(i * 255) for i in range(256)]


# --- the source picture -------------------------------------------------------------------
MAGIC = [[0, 6, 1, 7], [4, 2, 5, 3], [3, 5, 2, 4], [7, 1, 6, 0]]


def make_source(w, h, seed):
    """{'rgb8': [[(r,g,b)]], 'cvg': [[0..7]]}: shaded triangles, coverage partial on edges"""
    rnd = random.Random(seed)
    img = [[((x * 255) // max(1, w - 1), (y * 255) // max(1, h - 1), 96) for x in range(w)] for y in range(h)]
    cvg = [[7] * w for _ in range(h)]
    for _ in range(14):
        pts = [(rnd.uniform(-20, w + 20), rnd.uniform(-20, h + 20)) for _ in range(3)]
        cols = [tuple(rnd.randrange(256) for _ in range(3)) for _ in range(3)]
        (x0, y0), (x1, y1), (x2, y2) = pts
        area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
        if abs(area) < 50:
            continue
        for y in range(h):
            for x in range(w):
                # coverage: 8 samples in the pixel
                n = 0
                for sx, sy in ((0.125, 0.125), (0.625, 0.125), (0.375, 0.375), (0.875, 0.375),
                               (0.125, 0.625), (0.625, 0.625), (0.375, 0.875), (0.875, 0.875)):
                    px, py = x + sx, y + sy
                    w0 = ((x1 - px) * (y2 - py) - (x2 - px) * (y1 - py)) / area
                    w1 = ((x2 - px) * (y0 - py) - (x0 - px) * (y2 - py)) / area
                    if w0 >= 0 and w1 >= 0 and 1 - w0 - w1 >= 0:
                        n += 1
                if n == 0:
                    continue
                px, py = x + 0.5, y + 0.5
                w0 = ((x1 - px) * (y2 - py) - (x2 - px) * (y1 - py)) / area
                w1 = ((x2 - px) * (y0 - py) - (x0 - px) * (y2 - py)) / area
                w2 = 1 - w0 - w1
                c = tuple(max(0, min(255, int(w0 * cols[0][i] + w1 * cols[1][i] + w2 * cols[2][i]))) for i in range(3))
                img[y][x] = c
                cvg[y][x] = 7 if n == 8 else n - 1
    return img, cvg


def dith5(v, x, y):
    return min(31, (v + MAGIC[y & 3][x & 3]) >> 3)


def source_words(case):
    """the line buffer's words for every line, as the fetcher writes them: lines[L][k] = 144-bit int"""
    ps1, w, h, b32, hid_ok, opt, vist = CASES[case]
    img, cvg = make_source(w, h, sum(map(ord, case)))
    lines = []
    for y in range(h):
        words = []
        if b32:
            for k in range((w + 3) // 4):
                v = 0
                for i in range(4):
                    x = 4 * k + i
                    r, g, b = img[y][x] if x < w else (0, 0, 0)
                    a = (cvg[y][x] << 5) if x < w else 0
                    for j, byte in enumerate((r, g, b, a)):
                        v |= byte << (8 * (4 * i + j))
                words.append(v)
        else:
            for k in range((w + 7) // 8):
                v = 0
                hid = 0
                for i in range(8):
                    x = 8 * k + i
                    if x < w:
                        r, g, b = (dith5(c, x, y) for c in img[y][x])
                        cv = cvg[y][x]
                    else:
                        r = g = b = 0
                        cv = 7
                    if ps1:
                        v |= (r | g << 5 | b << 10) << (16 * i)
                    else:
                        p = r << 11 | g << 6 | b << 1 | (cv >> 2)
                        v |= (p >> 8) << (8 * (2 * i)) | (p & 0xFF) << (8 * (2 * i + 1))
                        hid |= (cv & 3) << (2 * i)
                words.append(v | (hid << 128 if hid_ok else 0))
        lines.append(words)
    return lines


# --- the model ----------------------------------------------------------------------------
def pix(word, k, ps1, b32, hok):
    if ps1:
        p = (word >> (16 * k)) & 0xFFFF
        r5, g5, b5 = p & 31, (p >> 5) & 31, (p >> 10) & 31
        return 7, (r5 << 3 | r5 >> 2), (g5 << 3 | g5 >> 2), (b5 << 3 | b5 >> 2)
    if b32:
        by = [(word >> (8 * (4 * k + j))) & 0xFF for j in range(4)]
        return by[3] >> 5, by[0], by[1], by[2]
    p = ((word >> (16 * k)) & 0xFF) << 8 | ((word >> (16 * k + 8)) & 0xFF)
    hb = (word >> (128 + 2 * k)) & 3 if hok else 3
    r5, g5, b5 = p >> 11, (p >> 6) & 31, (p >> 1) & 31
    return (p & 1) << 2 | hb, (r5 << 3 | r5 >> 2), (g5 << 3 | g5 >> 2), (b5 << 3 | b5 >> 2)


def model(case):
    ps1, w, h, b32, hok, opt, vist = CASES[case]
    lines = source_words(case)
    ppw = 4 if b32 else 8
    b32 = b32 and not ps1
    dbl = w <= 320
    hgt = h if h else 1
    xoff = 320 - w if dbl else 0
    span = 2 * w if dbl else w
    vf = (opt >> 4) & 3
    aam = (vist >> 8) & 3
    en_aa = not ps1 and ((vf == 0 and aam < 2) or vf == 2)
    en_dd = not ps1 and not b32 and ((vf == 0 and (vist >> 16) & 1) or vf == 2 or (opt >> 6) & 1)
    en_dv = not ps1 and ((vf == 0 and (vist >> 4) & 1) or vf == 2)
    en_gm = not ps1 and (vist >> 3) & 1 and not (opt >> 7) & 1
    if not dbl:
        scl = 1
    elif opt & 3:
        scl = opt & 3
    else:
        scl = 0 if (not ps1 and aam != 3) else 1
    scan = (opt >> 2) & 3 if dbl else 0

    cache = {}

    def P(row, x):
        x = max(0, min(w - 1, x))
        key = (row, x)
        if key not in cache:
            k, i = divmod(x, ppw)
            ws = lines[row] if row < len(lines) else []
            word = ws[k] if k < len(ws) else 0
            cache[key] = pix(word, i, ps1, b32, hok)
        return cache[key]

    fcache = {}

    def F(s, m):
        """the filters' answer for the window centred at m on source row s: (edge, rgb, above, below)"""
        if (s, m) in fcache:
            return fcache[(s, m)]
        su = 0 if s == 0 else s - 1
        sd = s if s + 1 >= hgt else s + 1
        A = [P(su, m + d) for d in (-1, 0, 1)]
        C = [P(s, m + d) for d in (-2, -1, 0, 1, 2)]
        B = [P(sd, m + d) for d in (-1, 0, 1)]
        cv = C[2][0]
        do_aa = en_aa and cv != 7
        out = []
        for ch in range(3):
            p = C[2][1 + ch]
            if do_aa:
                nb = [A[0], A[2], B[0], B[2], C[0], C[4]]
                # (at 5 bits: exact for a 16-bit frame, whose 8-bit values are 5-bit ones widened)
                vals = sorted([p >> 3] + [n[1 + ch] >> 3 for n in nb if n[0] == 7], reverse=True)
                pmax = vals[1] if len(vals) > 1 else vals[0]
                vals.sort()
                pmin = vals[1] if len(vals) > 1 else vals[0]
                pmax, pmin = pmax << 3 | pmax >> 2, pmin << 3 | pmin >> 2
                d = pmax + pmin - 2 * p
                t = d * (7 - cv) + 4
                o = p + (t >> 3)
                out.append(max(0, min(255, o)))
            elif en_dd:
                p5 = p >> 3
                nb = [A[0], A[1], A[2], C[1], C[3], B[0], B[1], B[2]]
                s5 = sum((n[1 + ch] >> 3) > p5 for n in nb) - sum((n[1 + ch] >> 3) < p5 for n in nb)
                out.append(max(0, min(255, p + s5)))
            else:
                out.append(p)
        r = (do_aa, tuple(out), A[1][1:], B[1][1:])
        fcache[(s, m)] = r
        return r

    def avg2(a, b):
        return tuple((a[i] + b[i]) >> 1 for i in range(3))

    def sim(a, b):
        return sum(abs(a[i] - b[i]) for i in range(3)) < 40

    def med3(a, b, c):
        return sorted((a, b, c))[1]

    def dim(v, how):
        return v - (v >> 2) if how == 1 else v >> 1 if how >= 2 else v

    out = [[(0, 0, 0)] * 640 for _ in range(480)]
    for Y in range(480):
        s = Y >> 1 if dbl else Y
        if s >= hgt:
            continue
        for X in range(640):
            rel = X - xoff
            if rel < 0 or rel >= span:
                continue
            j = rel >> 1 if dbl else rel
            qx = dbl and (rel & 1)
            qy = dbl and (Y & 1)
            # (every neighbour filtered: row s, the row above it, the row below)
            H0 = F(s, max(0, j - 1))
            H1 = F(s, j)
            H2 = F(s, j + 1)
            sb = min(s + 1, hgt - 1)
            hW, hP, hE = H0[1], H1[1], H2[1]
            hN = F(max(0, s - 1), j)[1]
            hS, hSE = F(sb, j)[1], F(sb, j + 1)[1]
            if en_dv and (H0[0] or H1[0] or H2[0]):
                dP = tuple(med3(hW[i], hP[i], hE[i]) for i in range(3))
            else:
                dP = hP
            s_r = avg2(dP, hE) if qx else dP
            if qy:
                s_b = avg2(avg2(dP, hE), avg2(hS, hSE)) if qx else avg2(dP, hS)
            else:
                s_b = s_r
            sNW, sNE, sSW, sSE = sim(hN, hW), sim(hN, hE), sim(hS, hW), sim(hS, hE)
            if scl == 0:
                v = s_r
            elif scl == 2:
                v = s_b
            elif scl == 3:
                if not qy and not qx:
                    v = avg2(dP, avg2(hN, hW)) if (sNW and not sNE and not sSW) else dP
                elif not qy:
                    v = avg2(dP, avg2(hN, hE)) if (sNE and not sNW and not sSE) else dP
                elif not qx:
                    v = avg2(dP, avg2(hS, hW)) if (sSW and not sSE and not sNW) else dP
                else:
                    v = avg2(dP, avg2(hS, hE)) if (sSE and not sSW and not sNE) else dP
            else:
                v = dP
            sd = scan if (scan and qy) else 0
            v = tuple(dim(c, sd) for c in v)
            if en_gm:
                v = tuple(GAM[c] for c in v)
            out[Y][X] = v
    return out


# --- files --------------------------------------------------------------------------------
def gen(case):
    ps1, w, h, b32, hok, opt, vist = CASES[case]
    os.makedirs(VD, exist_ok=True)
    lines = source_words(case)
    with open(os.path.join(VD, 'img.hex'), 'w') as f:
        for L in range(512):
            for k in range(128):
                ws = lines[L] if L < len(lines) else []
                f.write('%036x\n' % (ws[k] if k < len(ws) else 0))
    nwords = (w + 3) // 4 if b32 else (w + 7) // 8
    with open(os.path.join(VD, 'cfg.hex'), 'w') as f:
        for v in (ps1, w, h, b32, hok, opt, vist, nwords):
            f.write('%x\n' % v)


def check(case):
    exp = model(case)
    path = os.path.join(ROOT, 'build', 'sim-tb_n64_vid', 'out.hex')
    got = [int(l, 16) for l in open(path) if l.strip()]
    if len(got) != 640 * 480:
        print('%s: FAIL - the bench wrote %d pixels' % (case, len(got)))
        return False
    bad = 0
    first = None
    for Y in range(480):
        for X in range(640):
            e = exp[Y][X]
            ev = e[0] << 16 | e[1] << 8 | e[2]
            if got[Y * 640 + X] != ev:
                bad += 1
                if first is None:
                    first = (X, Y, ev, got[Y * 640 + X])
    if bad:
        print('%s: FAIL - %d pixels differ; first at (%d, %d): model %06x, rtl %06x' % ((case, bad) + first))
        return False
    print('%s: the picture matches the model (640 x 480)' % case)
    return True


def show(case):
    import zlib
    import struct
    img = model(case)
    raw = b''.join(b'\0' + bytes(c for px in row for c in px) for row in img)

    def chunk(t, d):
        c = struct.pack('>I', len(d)) + t + d
        return c + struct.pack('>I', zlib.crc32(t + d) & 0xFFFFFFFF)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 640, 480, 8, 2, 0, 0, 0)) + \
        chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b'')
    p = os.path.join(ROOT, 'build', 'vid_%s.png' % case)
    open(p, 'wb').write(png)
    print(p)


def main():
    cmd = sys.argv[1]
    if cmd == 'gen':
        gen(sys.argv[2])
    elif cmd == 'check':
        sys.exit(0 if check(sys.argv[2]) else 1)
    elif cmd == 'show':
        show(sys.argv[2])
    elif cmd == 'all':
        ok = True
        for c in (sys.argv[2:] or CASES):
            gen(c)
            r = subprocess.run(['bash', 'tools/sim.sh', 'tb_n64_vid'], cwd=ROOT, capture_output=True, text=True)
            if r.returncode != 0:
                print('%s: FAIL - the bench:\n%s' % (c, r.stdout[-1500:]))
                ok = False
                continue
            ok = check(c) and ok
        print('tb_n64_vid: all checks passed' if ok else 'tb_n64_vid: FAIL')
        sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
