"""Read the display list out of a frozen machine and print the shape of what it
asks for, so a polygon that LOOKS wrong on the screen can be compared with the
vertices the game actually sent.

    python tools/ps1shapes.py [x0 y0 x1 y1]     only polygons touching that box

Halts the processor (ctrl 0x04 bit 2 -- NOT bit 0, which is the core's RESET
and put the machine back at bfc00000, so everything this printed before
2026-09-26 was read off a machine that had just been reset), lets the drawing
engine drain, flushes
the write-back cache, walks the ordering table out of RAM and decodes every
primitive's vertices. Coordinates are as the game sent them, BEFORE the drawing
offset, which is what the GTE produced.
"""
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pc"))
import fpgalink as fl

N = 0x0008_0000
RAM_LINE = 0x10000
BOARD = fl.DEFAULT_HOST

SHAPES = {
    0x20:(4,[1,2,3]),      0x22:(4,[1,2,3]),
    0x28:(5,[1,2,3,4]),    0x2A:(5,[1,2,3,4]),
    0x24:(7,[1,3,5]),      0x25:(7,[1,3,5]),  0x26:(7,[1,3,5]),  0x27:(7,[1,3,5]),
    0x2C:(9,[1,3,5,7]),    0x2D:(9,[1,3,5,7]),0x2E:(9,[1,3,5,7]),0x2F:(9,[1,3,5,7]),
    0x30:(6,[1,3,5]),      0x32:(6,[1,3,5]),
    0x38:(8,[1,3,5,7]),    0x3A:(8,[1,3,5,7]),
    0x34:(9,[1,4,7]),      0x36:(9,[1,4,7]),
    0x3C:(12,[1,4,7,10]),  0x3E:(12,[1,4,7,10]),
}
NAME = {0x20:"tri flat",0x24:"tri tex",0x28:"quad flat",0x2C:"quad tex",0x2E:"quad tex semi",
        0x30:"tri gour",0x34:"tri gour tex",0x38:"quad gour",0x3C:"quad gour tex",
        0x3E:"quad gour tex semi",0x2D:"quad tex raw"}


def s11(v):
    v &= 0x7FF
    return v - 2048 if v & 0x400 else v


def main():
    box = [int(a) for a in sys.argv[1:5]] if len(sys.argv) >= 5 else None
    l = fl.Link(BOARD, 5005, timeout=1.0, retries=4)
    want = int(sys.argv[5]) if len(sys.argv) > 5 else 300   # a walk shorter than this caught the list mid-build
    run = l.read(N + 0x04)
    l.write(N + 0x04, run | 4)              # halt the processor where it stands
    time.sleep(0.25)
    l.write(N + 0x118, 1)                   # and flush its write-back cache
    for _ in range(300):
        if not (l.read(N + 0x118) & 1):
            break
    try:
        cache = {}
        def rdline(a):
            if a in cache: return cache[a]
            l.write(N + 0x7C, RAM_LINE + (a >> 4))
            for _ in range(40):
                if l.read(N + 0x7C) >> 31: break
            v = [l.read(N + 0x80 + 4 * k) for k in range(4)]
            cache[a] = v
            return v
        def words(a, n):
            out = []
            while len(out) < n:
                base = (a + 4 * len(out)) & ~0xF
                out += rdline(base)[((a + 4 * len(out)) >> 2) & 3:]
            return out[:n]

        # The DMA's trace holds the last sixteen nodes it read; whichever of them
        # is furthest back in the list gives the longest walk, and the list is
        # rebuilt every frame so a short walk catches only its tail.
        cands = []
        for i in range(16):
            l.write(N + 0x90, i)
            cands.append(l.read(N + 0x90) & 0xFFFFFF)
        best, start = -1, cands[0]
        for c in sorted(set(cands)):
            seen2, a2, n2 = set(), c, 0
            while a2 and a2 != 0xFFFFFF and a2 not in seen2 and n2 < 4000:
                seen2.add(a2); n2 += 1
                a2 = words(a2, 1)[0] & 0xFFFFFF
            if n2 > best: best, start = n2, c
        if best < want and not getattr(main, "_retry", 0) >= 8:
            main._retry = getattr(main, "_retry", 0) + 1
            l.write(N + 0x04, run & ~4)
            time.sleep(0.4 + 0.13 * main._retry)
            return main()
        print("walking the ordering table from %06x (%d nodes)" % (start, best))
        seen, shown, total = set(), 0, 0
        a = start
        t0 = time.time()
        while a and a != 0xFFFFFF and a not in seen and time.time() - t0 < 90:
            seen.add(a)
            hdr = words(a, 1)[0]
            n, nxt = hdr >> 24, hdr & 0xFFFFFF
            if 0 < n <= 16:
                ws = words(a + 4, n)
                op = ws[0] >> 24
                if op in SHAPES:
                    need, vi = SHAPES[op]
                    if n >= need:
                        total += 1
                        vs = [(s11(ws[k]), s11(ws[k] >> 16)) for k in vi]
                        xs = [v[0] for v in vs]; ys = [v[1] for v in vs]
                        if box and (max(xs) < box[0] or min(xs) > box[2]
                                    or max(ys) < box[1] or min(ys) > box[3]):
                            a = nxt; continue
                        shown += 1
                        if shown <= 40:
                            desc = NAME.get(op, "op%02x" % op)
                            s = "  @%06x %-20s " % (a, desc) + " ".join("(%4d,%4d)" % v for v in vs)
                            if len(vs) == 4:
                                # a flat quad's opposite sides are equal; the shear
                                # shows as the two diagonals disagreeing
                                d1 = (vs[3][0] - vs[0][0], vs[3][1] - vs[0][1])
                                d2 = (vs[2][0] - vs[1][0], vs[2][1] - vs[1][1])
                                s += "   sides (%+d,%+d) vs (%+d,%+d)" % (d1 + d2)
                            print(s)
            a = nxt
        print("  %d polygons in the list, %d in the box" % (total, shown))
    finally:
        l.write(N + 0x04, run & ~4)
        print("processor running again")


if __name__ == "__main__":
    main()
