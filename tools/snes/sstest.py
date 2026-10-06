"""sstest.py - tools/snes/w65816.py against the SingleStepTests 65816 suite
(sim/roms/snes/ss65816/XX.{e,n}.json, 10,000 tests each).

    python tools/snes/sstest.py [OPCODE_HEX ...] [--n N] [--cycles] [--show K]

For each test: the state and RAM set as `initial` says, one instruction, then the registers, the
RAM listed in `final`, and with --cycles the number of bus cycles, held against the suite's.
Prints a line an opcode/mode: how many of the first N tests pass, and the first failure.

Where this suite and gilyon's cputest (run on real hardware; tools/snes/snesmin.py) disagree, the
model follows the hardware, so these fail here on purpose: in emulation mode (dp,X) with DL != 0
(the pointer's high byte wraps in its page; 01 21 41 61 81 a1 c1 e1 .e, ~0.3%), and JSR (a,X)
pushing from S=$100 (fc.e, ~0.4%). MVN / MVP (44, 54) are sampled mid-instruction.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import w65816  # noqa: E402

DIR = os.path.join(HERE, '..', '..', 'sim', 'roms', 'snes', 'ss65816')
REGS = ('pc', 's', 'p', 'a', 'x', 'y', 'dbr', 'd', 'pbr', 'e')


def run_one(t, cycles, bus=False):
    mem = {}
    seq = []

    def rd(a):
        v = mem.get(a, 0)
        seq.append((a, v, 'r'))
        return v

    def wr(a, v):
        seq.append((a, v, 'w'))
        mem[a] = v
    c = w65816.CPU(rd, wr)
    io0 = c.io

    def io():
        seq.append((None, None, 'i'))
        io0()
    c.io = io
    i = t['initial']
    for a, v in i['ram']:
        mem[a] = v
    c.pc, c.s, c.a, c.x, c.y = i['pc'], i['s'], i['a'], i['x'], i['y']
    c.dbr, c.d, c.pbr, c.e, c.p = i['dbr'], i['d'], i['pbr'], i['e'], i['p']
    c.cycles = 0
    c.step()
    f = t['final']
    got = {'pc': c.pc, 's': c.s, 'p': c.p, 'a': c.a, 'x': c.x, 'y': c.y,
           'dbr': c.dbr, 'd': c.d, 'pbr': c.pbr, 'e': c.e}
    bad = [r for r in REGS if got[r] != f[r]]
    for a, v in f['ram']:
        if mem.get(a, 0) != v:
            bad.append('ram[%06x]=%02x want %02x' % (a, mem.get(a, 0), v))
    if cycles and c.cycles != len(t['cycles']):
        bad.append('cycles %d want %d' % (c.cycles, len(t['cycles'])))
    if bus and not bad:
        want = []
        for a, v, pins in t['cycles']:
            if pins[0] == '-' and pins[1] == '-':
                want.append((None, None, 'i'))          # (an internal cycle: neither VDA nor VPA)
            else:
                want.append((a, v, 'w' if pins[3] == 'w' else 'r'))
        if seq != want:
            k = next((k for k in range(min(len(seq), len(want))) if seq[k] != want[k]), min(len(seq), len(want)))
            bad.append('bus: cycle %d ours %s want %s' % (k, seq[k] if k < len(seq) else '-', want[k] if k < len(want) else '-'))
    return bad, got


def main():
    args = sys.argv[1:]
    n = int(args[args.index('--n') + 1]) if '--n' in args else 1000
    cycles = '--cycles' in args or '--bus' in args
    bus = '--bus' in args
    ops = [a for a in args if len(a) == 2 and all(ch in '0123456789abcdefABCDEF' for ch in a)]
    ops = [int(o, 16) for o in ops] or list(range(256))
    total = ok_all = 0
    for op in ops:
        for mode in 'en':
            path = os.path.join(DIR, '%02x.%s.json' % (op, mode))
            if not os.path.exists(path):
                continue
            tests = json.load(open(path))[:n]
            ok, first = 0, None
            for t in tests:
                bad, got = run_one(t, cycles, bus)
                if not bad:
                    ok += 1
                elif first is None:
                    first = (t['name'], bad[:4], {r: t['final'][r] for r in REGS}, got)
            total += 1
            ok_all += ok == len(tests)
            if ok != len(tests):
                print('%02x.%s  %5d/%d  first: %s %s' % (op, mode, ok, len(tests), first[0], first[1]))
    print('%d of %d opcode/mode files pass' % (ok_all, total))


if __name__ == '__main__':
    main()
