"""Where the N64's RDP spends its time on the board, sampled from the debug window.

    python tools/n64/n64rdpsample.py [SAMPLES]

Select 39 is n64_rdp2's dbg[63:32]: {walk state (3), doublewords gathered (5),
primitive busy, TMEM load busy, walk read waiting, raster on memory, TMEM on memory,
0 (3), the raster's state (5), fetch issuing, fetch phase, lines got (9)}.
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from n64dbg import reg, CTRL   # noqa: E402

SEL, DATA = CTRL + 0x170, CTRL + 0x174
RST = {0: 'IDLE', 1: 'PRIM', 2: 'Y', 3: 'K0', 4: 'K1', 5: 'SPAN', 6: 'ATTR', 7: 'AINIT', 8: 'PIX', 9: 'NEXT',
       10: 'FLUSH', 11: 'FWAIT', 12: 'DONE', 13: 'PUSH', 21: 'LINE', 22: 'DRAIN'}


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    what = collections.Counter(); rst = collections.Counter(); pend = 0
    for _ in range(n):
        reg(SEL, 39); w = reg(DATA)
        reg(SEL, 10); end = reg(DATA)
        reg(SEL, 11); cur = reg(DATA)
        if cur != end:
            pend += 1
        ws, pr, ld, wk, rm, tm = w >> 29, (w >> 23) & 1, (w >> 22) & 1, (w >> 21) & 1, (w >> 20) & 1, (w >> 19) & 1
        if pr:
            what['drawing a primitive'] += 1
            rst[RST.get((w >> 11) & 31, (w >> 11) & 31)] += 1
        elif ld:
            what['loading TMEM' + (' (on memory)' if tm else '')] += 1
        elif wk:
            what['walk waiting for a command line'] += 1
        elif cur != end:
            what['walk/decode (ws %d)' % ws] += 1
        else:
            what['idle'] += 1
    print('commands pending in %d%% of samples' % (100 * pend // n))
    for k, v in what.most_common():
        print('  %-36s %4.1f%%' % (k, 100.0 * v / n))
    tot = sum(rst.values())
    if tot:
        print('raster state while drawing:')
        for k, v in rst.most_common():
            print('  %-8s %4.1f%%' % (k, 100.0 * v / tot))


if __name__ == '__main__':
    main()
