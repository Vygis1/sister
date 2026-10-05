"""Groups tools/longpaths.tcl's endpoints by module: how many paths in each are
longer than a few clock periods, and the worst. Which module stops a faster clock.

    python tools/longpaths.py [build/longpaths.txt] [--depth N] [--show MODULE]
"""
import collections
import sys

LIMITS = (16.0, 14.0, 12.0, 10.0)


def module(cell, depth):
    parts = cell.split('/')[:-1]
    # (the console's wrappers are the same in every path: skip them)
    while parts and parts[0] in ('u_regs', 'u_console'):
        parts = parts[1:]
    return '/'.join(parts[:depth]) or '(top)'


def main():
    args = [a for a in sys.argv[1:]]
    depth = 3
    show = None
    if '--depth' in args:
        i = args.index('--depth'); depth = int(args[i + 1]); del args[i:i + 2]
    if '--show' in args:
        i = args.index('--show'); show = args[i + 1]; del args[i:i + 2]
    path = args[0] if args else 'build/longpaths.txt'
    rows = []
    for line in open(path):
        f = line.split() + ["(top)", "(top)"]
        d, lv, a, b = f[0], f[1], f[2], f[3]
        rows.append((float(d), int(lv), a, b))
    if show:
        for d, lv, a, b in sorted(rows, reverse=True):
            if module(b, 99).startswith(show) or module(a, 99).startswith(show):
                print('%6.2f ns %2d levels  %s -> %s' % (d, lv, a, b))
        return
    by = collections.defaultdict(list)
    for d, lv, a, b in rows:
        by[module(b, depth)].append((d, lv))
    print('%-46s %7s %7s %7s %7s  %s' % ('endpoint module', *('>%g' % x for x in LIMITS), 'worst'))
    for m, v in sorted(by.items(), key=lambda kv: -max(x[0] for x in kv[1])):
        w = max(v)
        print('%-46s %7d %7d %7d %7d  %.2f ns, %d levels' % (m[-46:], *(sum(1 for x in v if x[0] > L) for L in LIMITS), w[0], w[1]))


if __name__ == '__main__':
    main()
