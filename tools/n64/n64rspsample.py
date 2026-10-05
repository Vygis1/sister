"""Where the N64's RSP spends its time on the board: its program counter, sampled.

    python tools/n64/n64rspsample.py [SAMPLES]

Each sample reads the debug window's select 29 ({halted, task type, state, pc})
and select 30 (the instruction in hand), and DPC_STATUS. Prints, per task type,
the hottest PCs with their instructions, and how often the RDP was busy.
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from n64dbg import reg, CTRL   # noqa: E402

SEL, DATA = CTRL + 0x170, CTRL + 0x174
TYPES = {0: 'graphics', 1: 'audio', 2: 'other'}


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 400
    pcs = collections.Counter(); ins = {}; types = collections.Counter(); dpbusy = collections.Counter()
    for _ in range(n):
        reg(SEL, 29); w = reg(DATA)
        reg(SEL, 30); ir = reg(DATA)
        reg(SEL, 12); dps = reg(DATA)
        halted, t, pc = w >> 31, (w >> 29) & 3, w & 0xFFF
        dpbusy[(dps >> 5) & 3] += 1          # bit 5 pipe busy, bit 6 command busy
        if halted:
            types['halted'] += 1
            continue
        types[TYPES.get(t, t)] += 1
        pcs[(t, pc)] += 1
        ins[(t, pc)] = ir
    print('RSP: %s' % ', '.join('%s %d%%' % (k, 100 * v // n) for k, v in types.most_common()))
    print('RDP: pipe/cmd busy in %d%% of samples' % (100 * (n - dpbusy[0]) // n))
    for t in (0, 1):
        tot = sum(v for (tt, _), v in pcs.items() if tt == t)
        if not tot:
            continue
        print('%s, hottest PCs (%% of its samples):' % TYPES[t])
        for (tt, pc), v in pcs.most_common():
            if tt == t and v * 100 >= tot * 1.5:
                print('   %03x  %08x  %4.1f%%' % (pc, ins[(tt, pc)], 100.0 * v / tot))


if __name__ == '__main__':
    main()
