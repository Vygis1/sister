"""mkpersp.py - vectors for sim/tb_n64_rdp_persp.v: random and edge (s, t, w) through
tools/n64/n64rdp.py perspective_divide -> sim/n64d/persp.hex
    python tools/n64/mkpersp.py [N]"""
import os, random, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
import n64rdp
n = int(sys.argv[1]) if len(sys.argv) > 1 else 60000
rnd = random.Random(7)
def s16(v): return ((v + 0x8000) & 0xFFFF) - 0x8000
rows = []
edges = [0, 1, -1, 2, 0x7FFF, -0x8000, 0x4000, 0x3FFF, 0x100, 0xFF, 0x80]
while len(rows) < n:
    k = rnd.random()
    s = s16(rnd.choice(edges)) if k < 0.1 else s16(rnd.getrandbits(16))
    t = s16(rnd.getrandbits(16 if rnd.random() < .5 else rnd.randint(1, 16)))
    w = rnd.choice(edges) if k > 0.9 else s16(rnd.getrandbits(rnd.randint(1, 16)))
    so, to, ov = n64rdp.perspective_divide(s, t, w)
    rows.append(((s & 0xFFFF) << 83) | ((t & 0xFFFF) << 67) | ((w & 0xFFFF) << 51)
                | ((so & 0x1FFFF) << 34) | ((to & 0x1FFFF) << 17) | ((1 if ov else 0) << 16))
out = os.path.join(HERE, '..', '..', 'sim', 'n64d')
os.makedirs(out, exist_ok=True)
with open(os.path.join(out, 'persp.hex'), 'w') as f:
    f.write('%025x\n' % len(rows))
    for r in rows: f.write('%025x\n' % r)
print(len(rows), 'vectors')
