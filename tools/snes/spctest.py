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


def run_one(t, cycles, bus=False):
    mem = {}
    seq = []

    def rd(a):
        seq.append((a, 'r'))
        return mem.get(a, 0)

    def wr(a, v):
        seq.append((a, 'w', v))
        mem[a] = v
    c = spc700.SPC(rd, wr)
    idle0 = c.idle

    def idle(n=1):
        k = n - (1 if c._dummy else 0)     # (the model makes its first cycle a read: rd sees it)
        idle0(n)
        for _ in range(k):
            seq.append((None, 'i'))
    c.idle = idle
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
    if bus and not bad:
        want = []
        for a, v, ty in t['cycles']:
            want.append((None, 'i') if ty == 'wait' else (a, 'r') if ty == 'read' else (a, 'w', v))
        if seq != want:
            k = next((k for k in range(min(len(seq), len(want))) if seq[k] != want[k]), min(len(seq), len(want)))
            bad.append('bus: cycle %d ours %s want %s' % (k, seq[k] if k < len(seq) else '-', want[k] if k < len(want) else '-'))
    return bad, got


def main():
    args = sys.argv[1:]
    n = int(args[args.index('--n') + 1]) if '--n' in args else 1000
    cycles = '--cycles' in args or '--bus' in args
    bus = '--bus' in args
    ops = [int(a, 16) for a in args if len(a) == 2 and all(ch in '0123456789abcdefABCDEF' for ch in a)] or list(range(256))
    total = ok_all = 0
    for op in ops:
        path = os.path.join(DIR, '%02x.json' % op)
        if not os.path.exists(path):
            continue
        tests = json.load(open(path))[:n]
        ok, first = 0, None
        for t in tests:
            bad, got = run_one(t, cycles, bus)
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
