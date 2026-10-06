"""spc2vec.py - SingleStepTests spc700 cases as plain hex for sim/tb_spc700.v.

    python tools/snes/spc2vec.py OUT.vec [--n N]

Per test (hex): OPCODE; a x y sp psw pc; n (addr val)*n; n (addr val type)*n with type 0 read,
1 write, 2 internal (a dummy read's value is None in the suite: written 0, the bench reads
its memory); a x y sp psw pc after; n (addr val)*n after.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DIR = os.path.join(HERE, '..', '..', 'sim', 'roms', 'snes', 'ssspc700')
REGS = ('a', 'x', 'y', 'sp', 'psw', 'pc')


def main():
    args = sys.argv[1:]
    out = args[0]
    n = int(args[args.index('--n') + 1]) if '--n' in args else 200
    tests = []
    for op in range(256):
        for t in json.load(open(os.path.join(DIR, '%02x.json' % op)))[:n]:
            tests.append((op, t))
    with open(out, 'w') as f:
        f.write('%x\n' % len(tests))
        for op, t in tests:
            i, fin = t['initial'], t['final']
            f.write('%x\n' % op)
            f.write(' '.join('%x' % i[r] for r in REGS) + '\n')
            f.write('%x ' % len(i['ram']) + ' '.join('%x %x' % (a, v) for a, v in i['ram']) + '\n')
            cyc = []
            for a, v, ty in t['cycles']:
                if ty == 'wait':
                    cyc.append('0 0 2')
                else:
                    cyc.append('%x %x %d' % (a, v or 0, 1 if ty == 'write' else 0))
            f.write('%x ' % len(cyc) + ' '.join(cyc) + '\n')
            f.write(' '.join('%x' % fin[r] for r in REGS) + '\n')
            f.write('%x ' % len(fin['ram']) + ' '.join('%x %x' % (a, v) for a, v in fin['ram']) + '\n')
    print('%d tests -> %s' % (len(tests), out))


if __name__ == '__main__':
    main()
