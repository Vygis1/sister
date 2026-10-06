"""spctest.py - tools/snes/spc700.py against the SingleStepTests spc700 suite
(sim/roms/snes/ssspc700/XX.json).

    python tools/snes/spctest.py [OPCODE_HEX ...] [--n N] [--cycles]
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import spc700  # noqa: E402

DIR = os.path.join(HERE, '..', '..', 'sim', 'roms', 'snes', 'ssspc700')
REGS = ('pc', 'a', 'x', 'y', 'sp', 'psw')


def run_one(t, cycles):
    mem = {}
    c = spc700.SPC(lambda a: mem.get(a, 0), lambda a, v: mem.__setitem__(a, v))
    i = t['initial']
    for a, v in i['ram']:
        mem[a] = v
    c.pc, c.a, c.x, c.y, c.sp, c.psw = i['pc'], i['a'], i['x'], i['y'], i['sp'], i['psw']
    c.cycles = 0
    c.step()
    f = t['final']
    got = {'pc': c.pc, 'a': c.a, 'x': c.x, 'y': c.y, 'sp': c.sp, 'psw': c.psw}
    bad = [r for r in REGS if got[r] != f[r]]
    for a, v in f['ram']:
        if mem.get(a, 0) != v:
            bad.append('ram[%04x]=%02x want %02x' % (a, mem.get(a, 0), v))
    if cycles and c.cycles != len(t['cycles']):
        bad.append('cycles %d want %d' % (c.cycles, len(t['cycles'])))
    return bad, got


def main():
    args = sys.argv[1:]
    n = int(args[args.index('--n') + 1]) if '--n' in args else 1000
    cycles = '--cycles' in args
    ops = [int(a, 16) for a in args if len(a) == 2 and all(ch in '0123456789abcdefABCDEF' for ch in a)] or list(range(256))
    total = ok_all = 0
    for op in ops:
        path = os.path.join(DIR, '%02x.json' % op)
        if not os.path.exists(path):
            continue
        tests = json.load(open(path))[:n]
        ok, first = 0, None
        for t in tests:
            bad, got = run_one(t, cycles)
            if not bad:
                ok += 1
            elif first is None:
                first = (t['name'], bad[:4])
        total += 1
        ok_all += ok == len(tests)
        if ok != len(tests):
            print('%02x  %5d/%d  first: %s %s' % (op, ok, len(tests), first[0], first[1]))
    print('%d of %d opcodes pass' % (ok_all, total))


if __name__ == '__main__':
    main()
