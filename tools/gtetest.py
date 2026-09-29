"""Generate a self-checking sweep for the GTE, from the model in gte.py.

    python tools/gtetest.py [cases] > sim/roms/gte_vectors.hex

Each case is 129 words: 32 data registers and 32 control registers to load, the
command word, then the 32+32 register values the model reads back afterwards.
sim/tb_gte.v loads the same registers into the RTL, runs the command, and
compares every register. Values are written in realistic ranges most of the
time -- a rotation near 1.0, a vertex a few hundred units out, a projection
plane a few hundred deep -- with a minority pushed to the extremes, because the
overflow and saturation paths are where a GTE goes wrong and a sweep of only
sane inputs would never exercise them.

Registers with write side effects (SXYP, IRGB, LZCS, and the read-only ORGB and
LZCR) are not loaded: their state is derived, and skipping them keeps the
initial state identical on both sides.
"""
import random
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gte import GTE

SKIP_DATA = {29, 31}   # read-only; everything else is written, side effects and all

OPS = [
    (0x01, 8), (0x30, 8), (0x06, 3), (0x0C, 2), (0x10, 2), (0x2A, 2), (0x11, 2),
    (0x12, 8), (0x13, 4), (0x16, 4), (0x14, 2), (0x1B, 4), (0x3F, 3), (0x1C, 2),
    (0x1E, 3), (0x20, 2), (0x28, 2), (0x29, 2), (0x2D, 3), (0x2E, 3), (0x3D, 2),
    (0x3E, 2),
]


def r16(mostly=0x1000):
    """A 16-bit value, usually within +-mostly, sometimes anywhere."""
    if random.random() < 0.85:
        return random.randint(-mostly, mostly) & 0xFFFF
    return random.randint(-0x8000, 0x7FFF) & 0xFFFF


def r32(mostly=0x10000):
    if random.random() < 0.85:
        return random.randint(-mostly, mostly) & 0xFFFFFFFF
    return random.randint(-0x80000000, 0x7FFFFFFF) & 0xFFFFFFFF


def pack16(lo, hi):
    return (lo & 0xFFFF) | ((hi & 0xFFFF) << 16)


def gen_case():
    d = [0] * 32
    c = [0] * 32
    # vertices: a few hundred units out
    for n in range(3):
        d[2 * n] = pack16(r16(0x400), r16(0x400))
        d[2 * n + 1] = r16(0x800)
    d[6] = random.getrandbits(32)                      # RGBC
    d[7] = random.randint(0, 0xFFFF)                    # OTZ
    d[8] = random.randint(0, 0x1000) if random.random() < 0.9 else r16()   # IR0
    for i in (9, 10, 11):
        d[i] = r16(0x1000)
    for i in (12, 13, 14):                              # SXY fifo
        d[i] = pack16(r16(0x200), r16(0x200))
    for i in (16, 17, 18, 19):                          # SZ fifo
        # A third of the cases put SZ3 almost on top of the camera. That is where
        # the perspective divide overflows and where a game's geometry falls apart
        # if the clamp is wrong -- and it was never exercised: the old spread
        # almost never produced a depth under 100.
        r = random.random()
        if r < 0.33:   d[i] = random.randint(0, 80)
        elif r < 0.93: d[i] = random.randint(0, 0x2000)
        else:          d[i] = random.randint(0, 0xFFFF)
    for i in (20, 21, 22):                              # colour fifo
        d[i] = random.getrandbits(32)
    d[23] = random.getrandbits(32)
    for i in (24, 25, 26, 27):                          # MACs
        d[i] = r32(0x8000)
    # matrices: near a rotation of magnitude 1.0
    for base in (0, 8, 16):
        for i in range(5):
            c[base + i] = pack16(r16(0x1000), r16(0x1000))
    for i in (5, 6, 7):                                 # TR
        c[i] = r32(0x10000)
    for i in (13, 14, 15):                              # BK
        c[i] = r32(0x1000)
    for i in (21, 22, 23):                              # FC
        c[i] = r32(0x10000)
    c[24] = r32(0x100000); c[25] = r32(0x100000)        # OFX, OFY
    c[26] = random.randint(0x100, 0x400) if random.random() < 0.85 else random.randint(0, 0xFFFF)  # H
    c[27] = r16(0x100)                                  # DQA
    c[28] = r32(0x100000)                               # DQB
    c[29] = r16(0x1000); c[30] = r16(0x1000)            # ZSF3/4
    c[31] = 0

    op = random.choices([o for o, _ in OPS], weights=[w for _, w in OPS])[0]
    word = op
    if random.random() < 0.8: word |= 1 << 19            # sf: usually shift 12
    if random.random() < 0.5: word |= 1 << 10            # lm
    word |= random.randint(0, 3) << 17                   # mx
    word |= random.randint(0, 3) << 15                   # vx
    word |= random.randint(0, 3) << 13                   # cv
    word |= 1 << 24                                      # a command, not a move
    return d, c, word


def run_case(d, c, word):
    g = GTE()
    for i in range(32):
        if i in SKIP_DATA:
            continue
        g.write_data(i, d[i])
    for i in range(32):
        g.write_ctrl(i, c[i])
    g.op(word)
    outd = [g.read_data(i) for i in range(32)]
    outc = [g.read_ctrl(i) for i in range(32)]
    return outd, outc


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 2000
    random.seed(1234)
    out = []
    for _ in range(n):
        d, c, word = gen_case()
        outd, outc = run_case(d, c, word)
        for v in d: out.append(v)
        for v in c: out.append(v)
        out.append(word)
        for v in outd: out.append(v)
        for v in outc: out.append(v)
    sys.stdout.write("\n".join("%08x" % (v & 0xFFFFFFFF) for v in out) + "\n")
    sys.stderr.write("%d cases, %d words\n" % (n, len(out)))


if __name__ == "__main__":
    main()
