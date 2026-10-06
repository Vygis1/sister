"""sst2vec.py - SingleStepTests 65816 cases as plain hex for sim/tb_w65816.v.

    python tools/snes/sst2vec.py OUT.vec [--n N] [OPCODE_HEX ...]

Per test (all hex, whitespace-separated):
    pc s p a x y dbr d pbr e            the state before
    n  (addr val) * n                   memory before
    n  (addr val type) * n              every bus cycle: type 0 read, 1 write, 2 internal
    pc s p a x y dbr d pbr e            the state after
    n  (addr val) * n                   memory after
The file starts with the number of tests; each test's opcode and mode follow its count
line as a comment-free tag: OPCODE MODE(0 e, 1 n).

Left out: the cases where the suite and real hardware (gilyon's cputest) disagree -- found
by running the bus-exact model (tools/snes/w65816.py, which follows the hardware) on each
and dropping those it does not match. MVN / MVP are kept (the model cannot stop mid-block).
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sstest  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DIR = os.path.join(HERE, '..', '..', 'sim', 'roms', 'snes', 'ss65816')
REGS = ('pc', 's', 'p', 'a', 'x', 'y', 'dbr', 'd', 'pbr', 'e')


def main():
    args = sys.argv[1:]
    out = args[0]
    n = int(args[args.index('--n') + 1]) if '--n' in args else 200
    rest = [a for k, a in enumerate(args[1:], 1) if not a.startswith('--') and args[k - 1] != '--n']
    ops = [int(a, 16) for a in rest if len(a) == 2 and all(c in '0123456789abcdefABCDEF' for c in a)]
    ops = ops or list(range(256))
    tests = []
    skipped = []
    for op in ops:
        for mi, mode in enumerate('en'):
            path = os.path.join(DIR, '%02x.%s.json' % (op, mode))
            if os.path.exists(path):
                for t in json.load(open(path))[:n]:
                    if op not in (0x44, 0x54) and sstest.run_one(t, True, True)[0]:
                        skipped.append(t['name'])
                        continue
                    tests.append((op, mi, t))
    with open(out, 'w') as f:
        f.write('%x\n' % len(tests))
        for op, mi, t in tests:
            i, fin = t['initial'], t['final']
            f.write('%x %x\n' % (op, mi))
            f.write(' '.join('%x' % i[r] for r in REGS) + '\n')
            f.write('%x ' % len(i['ram']) + ' '.join('%x %x' % (a, v) for a, v in i['ram']) + '\n')
            cyc = []
            for a, v, pins in t['cycles']:
                if pins[0] == '-' and pins[1] == '-':
                    cyc.append('%x %x 2' % ((a or 0) & 0xFFFFFF, 0))
                else:
                    cyc.append('%x %x %d' % (a, v if v is not None else 0, 1 if pins[3] == 'w' else 0))
            f.write('%x ' % len(cyc) + ' '.join(cyc) + '\n')
            f.write(' '.join('%x' % fin[r] for r in REGS) + '\n')
            f.write('%x ' % len(fin['ram']) + ' '.join('%x %x' % (a, v) for a, v in fin['ram']) + '\n')
    print('%d tests -> %s (%d left out: the suite and the hardware disagree)' % (len(tests), out, len(skipped)))


if __name__ == '__main__':
    main()
