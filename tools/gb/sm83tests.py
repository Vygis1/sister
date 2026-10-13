"""Converts the SingleStepTests sm83 suite into one flat hex stream for sim/tb_gb_cpu.v.

    git clone https://github.com/SingleStepTests/sm83 build/sm83tests
    python tools/gb/sm83tests.py                      -> build/sm83tests/all.hex
    python tools/gb/sm83tests.py cb46 76 10           -> only those opcodes

The JSON is 161 MB and xsim has no JSON reader, so each test becomes a run of
hex words the bench pulls out with $fscanf. One record, all words in hex:

    id                         opcode: 00-FF, or 1xx for CB xx
    pc sp a f b c d e h l ime  the initial state
    n  (addr data) * n         initial RAM
    pc sp a f b c d e h l ime ei   the final state; ei is 0/1, or 2 when the test
                                   does not say (only EI's tests do)
    n  (addr data) * n         final RAM
    n  (type addr data) * n    the bus, one entry per M-cycle: type 0 idle, 1 read,
                               2 write. The suite's idle entries carry whatever
                               was last on the bus, so only the type is checked.
"""
import json
import os
import sys

SRC = os.path.join('build', 'sm83tests', 'v1')
OUT = os.path.join('build', 'sm83tests', 'all.hex')


def conv(name):
    tests = json.load(open(os.path.join(SRC, name + '.json')))
    words = []
    opid = int(name.replace('cb ', '1'), 16)
    for t in tests:
        i, f = t['initial'], t['final']
        words.append(opid)
        for s in (i, f):
            words += [s['pc'], s['sp'], s['a'], s['f'], s['b'], s['c'], s['d'], s['e'], s['h'], s['l'], s['ime']]
            if s is f:
                words.append(f.get('ei', 2))
            words.append(len(s['ram']))
            for a, d in s['ram']:
                words += [a, d]
        words.append(len(t['cycles']))
        for a, d, k in t['cycles']:
            ty = 1 if 'r' in k else 2 if 'w' in k else 0
            words += [ty, a if a is not None else 0, d if d is not None else 0]
    return words, len(tests)


def main():
    names = sorted(f[:-5] for f in os.listdir(SRC) if f.endswith('.json'))
    if len(sys.argv) > 1:
        want = [a.lower() for a in sys.argv[1:]]
        names = [n for n in names if n.replace(' ', '') in want]
    n = 0
    with open(OUT, 'w') as out:
        for name in names:
            w, cnt = conv(name)
            n += cnt
            out.write(' '.join('%x' % x for x in w))
            out.write('\n')
    print('%d tests from %d opcodes -> %s' % (n, len(names), OUT))


if __name__ == '__main__':
    main()
