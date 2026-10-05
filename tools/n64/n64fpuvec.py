"""Test vectors for rtl/vr4300_fpu.v, from tools/n64/n64fpu.py.

    python tools/n64/n64fpuvec.py [N] > sim/n64/fpu_vectors.hex

Each line is one operation and what the model says it does, in hex fields:
  fmt fn a b ctl  wr trap cause flags res cmp_wr cmp_val
ctl is FCR31's rounding mode, enables and FS packed as {fs, en[4:0], rm[1:0]}.
The operands are random but drawn mostly from the values where floating point
goes wrong: zeros, subnormals, the extremes, infinities, both kinds of NaN,
halfway cases, and integers at the edges of the conversions' ranges.
"""
import random
import sys

import n64fpu

M64 = (1 << 64) - 1


class FakeCPU:
    def __init__(self):
        self.status = (1 << 29) | (1 << 26)     # CU1, FR: no register pairing
        self.r = [0] * 32

    def branch(self, *a): pass
    def no_branch(self): pass
    def skip(self): pass


def specials(f):
    w, p = f.width, f.p
    sign = 1 << (w - 1)
    emask = f.emask << (p - 1)
    vals = [0, 1, f.mmask, 1 << (p - 1), emask - 1, emask,           # zero, subnormals, min normal, max, inf
            emask | 1, emask | f.qbit, emask | f.mmask,               # NaNs: quiet (bit clear) and signalling
            (f.bias << (p - 1)),                                      # 1.0
            ((f.bias + 1) << (p - 1)) | (1 << (p - 2)),               # 3.0
            ((f.bias - 1) << (p - 1)),                                # 0.5
            ((f.bias - 1) << (p - 1)) | f.mmask,                      # just under 1
            ((f.emax - 1 + f.bias) << (p - 1)) | f.mmask,             # near overflow
            ((f.emin + 1 + f.bias - 1) << (p - 1)) | f.mmask,         # near underflow
            ((f.emin + f.bias) << (p - 1)) | 1]
    for e in (31, 30, 32, 52, 53, 54, 55, 23, 24, 0, -1, -2, 62, 63):
        for m in (0, 1, f.mmask, 1 << (p - 2), f.mmask - 1):
            vals.append(((e + f.bias) << (p - 1)) | m)
    return vals + [v | sign for v in vals]


def rand_val(f, rng):
    k = rng.random()
    if k < 0.35:
        return rng.choice(specials(f))
    if k < 0.75:
        # a normal with an exponent anywhere, or near the middle
        e = rng.randint(1, f.emask - 1) if rng.random() < 0.4 else rng.randint(f.bias - 70, f.bias + 70)
        m = rng.getrandbits(f.p - 1)
        if rng.random() < 0.3:
            m &= ~((1 << rng.randint(0, f.p - 2)) - 1)                # trailing zeros: exact cases
        return (rng.getrandbits(1) << (f.width - 1)) | (e << (f.p - 1)) | m
    return rng.getrandbits(f.width)


def rand_int(bits, rng):
    k = rng.random()
    if k < 0.3:
        v = rng.choice([0, 1, -1, 2 ** 31 - 1, -2 ** 31, 2 ** 31, 2 ** 24 + 1, 2 ** 53 + 1, 2 ** 55 - 1,
                        -2 ** 55, 2 ** 55, 2 ** 63 - 1, -2 ** 63, 0x7FFFFFC0, 0x7FFFFFFF])
    elif k < 0.7:
        v = rng.getrandbits(rng.randint(1, 56)) * rng.choice([1, -1])
    else:
        v = rng.getrandbits(bits)
    return v & ((1 << bits) - 1)


FNS_FP = [0, 1, 2, 3, 4, 5, 7] * 3 + list(range(0x08, 0x10)) + [0x20, 0x21, 0x24, 0x25] * 2 \
         + list(range(0x30, 0x40)) + [0x10, 0x22, 0x26]


def one(rng):
    fmt = rng.choice([16, 17, 16, 17, 16, 17, 20, 21])
    if fmt in (16, 17):
        fn = rng.choice(FNS_FP)
        f = n64fpu.S if fmt == 16 else n64fpu.D
        a, b = rand_val(f, rng), rand_val(f, rng)
        if rng.random() < 0.15:
            b = a ^ rng.choice([0, 1, 1 << (f.width - 1)])            # equal, neighbours, negations
    else:
        fn = rng.choice([0x20, 0x21, 0x20, 0x21, 0x24, 0x08])
        a = rand_int(32 if fmt == 20 else 64, rng)
        b = 0
    rm = rng.randint(0, 3)
    en = rng.choice([0, 0, 0, rng.getrandbits(5), 1 << 4, 0x1F])
    fs = rng.randint(0, 1)
    return fmt, fn, a, b, rm, en, fs


def run(fmt, fn, a, b, rm, en, fs):
    cpu = FakeCPU()
    fpu = n64fpu.FPU(cpu)
    fpu.r[1] = a & M64
    fpu.r[2] = b & M64
    sentinel = 0x5A5A_A5A5_DEAD_BEEF
    fpu.r[3] = sentinel
    fpu.fcr31 = rm | (en << 7) | (fs << 24)
    w = (0x11 << 26) | (fmt << 21) | (2 << 16) | (1 << 11) | (3 << 6) | fn
    trap = 0
    try:
        fpu.execute(w, 0, 0)
    except n64fpu.Trap:
        trap = 1
    res = fpu.r[3]
    wr = int(res != sentinel)
    cause = fpu.fcr31 >> 12 & 0x3F
    flags = fpu.fcr31 >> 2 & 0x1F
    is_cmp = fmt in (16, 17) and fn >= 0x30
    cmp_wr = int(is_cmp and not trap)
    cmp_val = fpu.fcr31 >> 23 & 1 if cmp_wr else 0
    return wr, trap, cause, flags, (res if wr else 0), cmp_wr, cmp_val


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
    rng = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 64)
    for _ in range(n):
        fmt, fn, a, b, rm, en, fs = one(rng)
        wr, trap, cause, flags, res, cw, cv = run(fmt, fn, a, b, rm, en, fs)
        ctl = (fs << 7) | (en << 2) | rm
        print('%02x %02x %016x %016x %02x %x %x %02x %02x %016x %x %x' %
              (fmt, fn, a, b, ctl, wr, trap, cause, flags, res, cw, cv))


if __name__ == '__main__':
    main()
