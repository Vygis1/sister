"""Random test vectors for the RDP's RTL stages, from tools/n64/n64rdp.py.

    python tools/n64/n64rdpvec.py cc N [SEED]      -> sim/n64d/cc_vec.hex (sim/tb_n64_rdp_cc.v)
"""
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import n64rdp  # noqa: E402

OUT = os.path.join(HERE, '..', '..', 'sim', 'n64d')


def cc(n, seed):
    rnd = random.Random(seed)
    lines = []
    for _ in range(n):
        sel = (rnd.randrange(16), rnd.randrange(16), rnd.randrange(32), rnd.randrange(8),
               rnd.randrange(8), rnd.randrange(8), rnd.randrange(8), rnd.randrange(8))
        prim, env = rnd.getrandbits(32), rnd.getrandbits(32)
        kcen = [rnd.randrange(256) for _ in range(3)]
        kscl = [rnd.randrange(256) for _ in range(3)]
        conv = [0, 0, 0, 0, rnd.randrange(512), rnd.randrange(512)]
        plf = rnd.randrange(256)
        k = n64rdp.combiner_constants(sel, prim, env, kcen, kscl, conv, plf)
        I = n64rdp.CombinerInputs()
        r9 = lambda: rnd.randrange(-256, 512) if rnd.random() < 0.3 else rnd.randrange(256)
        I.combined = [r9() for _ in range(4)]
        I.texel0 = [r9() for _ in range(4)]
        I.texel1 = [r9() for _ in range(4)]
        I.shade = [rnd.randrange(256) for _ in range(4)]
        I.lod_frac = rnd.randrange(256)
        I.noise = ((rnd.randrange(8)) << 6) | 0x20
        out = n64rdp.combiner_raw(sel, k, I)
        p10 = lambda v: '%03x' % (v & 0x3FF)
        fields = ['%x' % s for s in sel] + ['%08x' % prim, '%08x' % env,
                  '%06x' % ((kcen[0] << 16) | (kcen[1] << 8) | kcen[2]), '%06x' % ((kscl[0] << 16) | (kscl[1] << 8) | kscl[2]),
                  '%03x' % conv[4], '%03x' % conv[5], '%02x' % plf]
        for v4 in (I.combined, I.texel0, I.texel1, I.shade):
            fields += [p10(v) for v in v4]
        fields += ['%03x' % I.lod_frac, '%03x' % I.noise]
        fields += ['%03x' % (v & 0x1FF) for v in out]
        lines.append(' '.join(fields))
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, 'cc_vec.hex'), 'w') as f:
        f.write('%x\n' % n)
        f.write('\n'.join(lines) + '\n')
    print('%d combiner vectors' % n)


if __name__ == '__main__':
    what = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 2000
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    {'cc': cc}[what](n, seed)
