"""Sweep the live display list out of RAM and count polygons with a runaway vertex.

    python tools/ps1/ps1vertex.py [sweeps]

A polygon whose vertices span more than the screen cannot be right: at about 1%
of Crash's polygons (measured 2026-09-23) it draws as a smear across the
picture, and a character made of them looks like it is twisting. This reads the
ordering table the DMA is walking, follows it to the end, decodes every
primitive's vertices, and reports how many are impossible -- so a change can be
judged by a number instead of by squinting at the picture.

Runs against the board through the DDR3 line window (ctrl 0x7C/0x80), after
flushing the processor's write-back cache (ctrl 0x118) so RAM is current.
"""
import os, sys, time, collections
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "pc"))
import fpgalink as fl

N = 0x0008_0000
RAM_LINE = 0x10000
BOARD = fl.DEFAULT_HOST

# command -> (words, vertex word indices within the packet)
#   flat tri 0x20: colour, v0, v1, v2
#   tex  tri 0x24: colour, v0, uv0, v1, uv1, v2, uv2
#   gouraud tri 0x30: c0, v0, c1, v1, c2, v2
#   gouraud tex tri 0x34/0x3C/0x3E: c0, v0, uv0, c1, v1, uv1, c2, v2, uv2
SHAPES = {
    0x20: (4, [1, 2, 3]),            0x22: (4, [1, 2, 3]),
    0x28: (5, [1, 2, 3, 4]),         0x2A: (5, [1, 2, 3, 4]),
    0x24: (7, [1, 3, 5]),            0x25: (7, [1, 3, 5]),
    0x26: (7, [1, 3, 5]),            0x27: (7, [1, 3, 5]),
    0x2C: (9, [1, 3, 5, 7]),         0x2D: (9, [1, 3, 5, 7]),
    0x2E: (9, [1, 3, 5, 7]),         0x2F: (9, [1, 3, 5, 7]),
    0x30: (6, [1, 3, 5]),            0x32: (6, [1, 3, 5]),
    0x38: (8, [1, 3, 5, 7]),         0x3A: (8, [1, 3, 5, 7]),
    0x34: (9, [1, 4, 7]),            0x36: (9, [1, 4, 7]),
    0x3C: (12, [1, 4, 7, 10]),       0x3E: (12, [1, 4, 7, 10]),
}


def s11(v):
    v &= 0x7FF
    return v - 2048 if v & 0x400 else v


def main():
    sweeps = int(sys.argv[1]) if len(sys.argv) > 1 else 40
    l = fl.Link(BOARD, 5005, timeout=1.0, retries=4)
    tot_prims = tot_bad = 0
    tot_ops = collections.Counter()
    worst = []

    def rdline(a, cache):
        if a in cache: return cache[a]
        l.write(N + 0x7C, RAM_LINE + (a >> 4))
        for _ in range(40):
            if l.read(N + 0x7C) >> 31: break
        v = [l.read(N + 0x80 + 4 * k) for k in range(4)]
        cache[a] = v
        return v

    for sweep in range(sweeps):
        cache = {}
        def words(a, n):
            out = []
            while len(out) < n:
                base = (a + 4 * len(out)) & ~0xF
                out += rdline(base, cache)[((a + 4 * len(out)) >> 2) & 3:]
            return out[:n]
        l.write(N + 0x118, 1)
        for _ in range(200):
            if not (l.read(N + 0x118) & 1): break
        # the sixteen linked-list headers the DMA read most recently: real
        # primitives, sampled from wherever the machine happens to be
        prims = bad = 0
        for i in range(16):
            l.write(N + 0x90, i)
            a = l.read(N + 0x90) & 0xFFFFFF
            hdr = l.read(N + 0x94)
            n = hdr >> 24
            if not (0 < n <= 16): continue
            ws = words(a + 4, n)
            op = ws[0] >> 24
            tot_ops[op] += 1
            if op not in SHAPES: continue
            need, vi = SHAPES[op]
            if n < need: continue
            xs = [s11(ws[k]) for k in vi]
            ys = [s11(ws[k] >> 16) for k in vi]
            prims += 1
            if max(xs) - min(xs) > 512 or max(ys) - min(ys) > 384:
                bad += 1
                if len(worst) < 10:
                    worst.append((a, op, list(zip(xs, ys))))
        tot_prims += prims; tot_bad += bad
        if sweep % 10 == 9:
            print(f"  after {sweep+1:3d} samples: {tot_prims:5d} polygons, "
                  f"{tot_bad:4d} with a runaway vertex ({100.0*tot_bad/max(tot_prims,1):.2f}%)")

    print()
    print(f"  {tot_bad} of {tot_prims} polygons span more than the screen"
          f"  = {100.0 * tot_bad / max(tot_prims,1):.2f}%")
    print("  commands seen: " + "  ".join(f"{o:02x}x{c}" for o, c in tot_ops.most_common(12)))
    for a, op, vs in worst:
        print(f"    @{a:06x} op{op:02x}  " + "  ".join(f"({x},{y})" for x, y in vs))


if __name__ == "__main__":
    main()
