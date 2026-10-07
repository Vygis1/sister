"""gtetrace.py - what loaded the GTE before a projection: the GTE stopped (the snapshot, console
0x190) just before an RTPS/RTPT, and its write trace (0x198-0x1A4: the last 64 MTC2/CTC2/LWC2
writes, each with the PC it was taken at) read out, oldest first. The rotation matrix is control
registers 0-4; translation 5-7; the vertices data 0-5.

    python tools/ps1/gtetrace.py [TRIES]      (through pc/pad.py's port; a game running)
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gtesnap  # noqa: E402

N = 0x80000
DNAME = ['VXY0', 'VZ0', 'VXY1', 'VZ1', 'VXY2', 'VZ2', 'RGBC', 'OTZ', 'IR0', 'IR1', 'IR2', 'IR3', 'SXY0', 'SXY1',
         'SXY2', 'SXYP', 'SZ0', 'SZ1', 'SZ2', 'SZ3', 'RGB0', 'RGB1', 'RGB2', 'RES1', 'MAC0', 'MAC1', 'MAC2', 'MAC3',
         'IRGB', 'ORGB', 'LZCS', 'LZCR']
CNAME = ['RT11RT12', 'RT13RT21', 'RT22RT23', 'RT31RT32', 'RT33', 'TRX', 'TRY', 'TRZ', 'L11L12', 'L13L21', 'L22L23',
         'L31L32', 'L33', 'RBK', 'GBK', 'BBK', 'LR1LR2', 'LR3LG1', 'LG2LG3', 'LB1LB2', 'LB3', 'RFC', 'GFC', 'BFC',
         'OFX', 'OFY', 'H', 'DQA', 'DQB', 'ZSF3', 'ZSF4', 'FLAG']


def main():
    tries = int(sys.argv[1]) if len(sys.argv) > 1 else 40
    p = gtesnap.Port()
    for _ in range(tries):
        p.w(gtesnap.SNAP, 0)
        p.w(gtesnap.SNAP, 0x80000000 | random.randrange(0, 200))
        st = gtesnap.wait(p, 25)
        if st is None:
            continue
        op = st & 0x3F
        if op not in (0x01, 0x30):
            p.w(gtesnap.SNAP, 0)
            continue
        print('stopped before %s (%07x); the writes before it, oldest first:' % ('RTPS' if op == 1 else 'RTPT', st & 0x1FFFFFF))
        for i in range(64):
            p.w(N + 0x198, i)
            pc, v, r = p.r(N + 0x19C), p.r(N + 0x1A0), p.r(N + 0x1A4)
            ctl, reg = (r >> 5) & 1, r & 31
            name = ('c%-2d %-9s' % (reg, CNAME[reg])) if ctl else ('d%-2d %-9s' % (reg, DNAME[reg]))
            mark = '  <-- the rotation matrix' if ctl and reg <= 4 else ''
            print('  %2d  pc %08x  %s = %08x%s' % (i, pc, name, v, mark))
        rt = [p.r(N + 0x194) for _ in range(0)]  # (the live registers are gtesnap's job)
        p.w(gtesnap.SNAP, 0)
        return
    p.w(gtesnap.SNAP, 0)
    print('no RTPS/RTPT caught in %d tries' % tries)


if __name__ == '__main__':
    main()
