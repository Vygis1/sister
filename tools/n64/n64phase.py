"""SM64's speed on the board, phase by phase: frames a second every few seconds,
and, for the slow phase (the title's Mario head) and the fast one, the CPU's stalls.

    python tools/n64/n64phase.py [MINUTES]
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from n64dbg import reg, CTRL   # noqa: E402

SEL, DATA = CTRL + 0x170, CTRL + 0x174
STALLS = ['load-use', 'mul/div', 'FP reg in flight', 'FPU busy', 'data TLB', 'data cache (W)', 'fetch (D)', 'fetch TLB']


def rd(s):
    reg(SEL, s); return reg(DATA)


def rate(secs=2.0):
    a = rd(20); t0 = time.time(); time.sleep(secs); b = rd(20)
    return ((b - a) & 0xFFFFFFFF) / (time.time() - t0)


def stalls():
    out = []
    for s in range(8):
        reg(SEL, (s << 8) | 46); n0 = reg(DATA); t0 = time.time(); time.sleep(0.6); n1 = reg(DATA)
        out.append(100.0 * ((n1 - n0) & 0xFFFFFFFF) / ((time.time() - t0) * 5e7))
    return out


def main():
    mins = float(sys.argv[1]) if len(sys.argv) > 1 else 3.0
    t_end = time.time() + 60 * mins
    rates = []
    seen = {}
    while time.time() < t_end:
        r = rate()
        rates.append(r)
        ph = 'slow' if r < 26 else 'fast'
        if ph not in seen and (r < 23 or r > 28.5):
            seen[ph] = (r, stalls())
    slow = [r for r in rates if r < 26]; fast = [r for r in rates if r >= 26]
    print('frames a second, every 2 s: %s' % ' '.join('%.0f' % r for r in rates))
    if slow: print('slow phase: %.1f on average (%d samples)' % (sum(slow) / len(slow), len(slow)))
    if fast: print('fast phase: %.1f on average (%d samples)' % (sum(fast) / len(fast), len(fast)))
    for ph, (r, st) in seen.items():
        print('%s phase at %.1f/s, CPU stalls: %s' % (ph, r, ', '.join('%s %.1f%%' % (n, v) for n, v in zip(STALLS, st) if v > 0.05)))


if __name__ == '__main__':
    main()
