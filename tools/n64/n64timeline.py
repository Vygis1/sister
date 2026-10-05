"""The N64 core's timeline (n64_top.v, "the timeline"): what happened when, frame by
frame, for working out where a frame's time goes.

    python tools/n64/n64timeline.py [--raw]

The log is frozen while it is read (dbg_sel[29]), so the 512 entries are one
stretch of time, about the last half second. For each frame (DP interrupt to DP
interrupt: SM64 ends every frame's display list with a full sync) it prints how
long it took and, within it, the CPU's time outside its idle loop, the RSP's on
graphics and on audio, and the VI interrupts that fell in it.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from n64dbg import reg, CTRL   # noqa: E402

SEL, DATA = CTRL + 0x170, CTRL + 0x174
CLK = 50_000_000
NAMES = {1: 'RSP gfx start', 2: 'RSP audio start', 3: 'RSP other start', 4: 'RSP gfx halt', 5: 'RSP audio halt',
         6: 'RSP other halt', 7: 'DP full sync', 8: 'VI', 9: 'AI', 10: 'CPU idle', 11: 'CPU busy'}


def read_log():
    frz = (1 << 31) | (1 << 29)
    reg(SEL, frz | (1 << 30))
    wp = reg(DATA) & 511
    out = []
    for k in range(512):
        i = (wp + k) & 511
        reg(SEL, frz | (i << 8))
        out.append(reg(DATA))
    reg(SEL, 0)                                    # running again
    ev, t, last = [], 0, None
    for w in out:
        code, c = w >> 28, w & 0x0FFFFFFF
        if code == 0:
            continue                               # (never written)
        if last is not None:
            t += (c - last) & 0x0FFFFFFF
        last = c
        ev.append((t, code))
    return ev


def frames(ev):
    """per frame: its length and what was busy in it (clocks)"""
    dp = [t for t, c in ev if c == 7]
    rows = []
    for a, b in zip(dp, dp[1:]):
        busy = {'cpu': 0, 'gfx': 0, 'audio': 0}
        vi = sum(1 for t, c in ev if c == 8 and a <= t < b)
        # intervals: CPU busy (11 .. 10), RSP gfx (1 .. 4), audio (2 .. 5), clipped to [a, b)
        for name, on, off in (('cpu', 11, 10), ('gfx', 1, 4), ('audio', 2, 5)):
            st = None
            for t, c in ev:
                if c == on and st is None:
                    st = t
                elif c == off and st is not None:
                    lo, hi = max(st, a), min(t, b)
                    if hi > lo:
                        busy[name] += hi - lo
                    st = None
        rows.append((a, b - a, vi, busy))
    return rows


def main():
    ev = read_log()
    if '--raw' in sys.argv:
        t0 = ev[0][0] if ev else 0
        for t, c in ev:
            print('%9.3f ms  %s' % ((t - t0) / CLK * 1000, NAMES.get(c, c)))
        return
    rows = frames(ev)
    if not rows:
        print('no two DP full syncs in the log (%d events)' % len(ev))
        return
    print('  frame ms   VIs   CPU busy   RSP gfx  RSP audio')
    tot = {'cpu': 0, 'gfx': 0, 'audio': 0}; span = 0
    for a, n, vi, b in rows:
        print('  %7.2f   %3d   %6.1f%%   %6.1f%%   %6.1f%%' % (n / CLK * 1000, vi, 100.0 * b['cpu'] / n, 100.0 * b['gfx'] / n, 100.0 * b['audio'] / n))
        for k in tot:
            tot[k] += b[k]
        span += n
    print('  %d frames, %.2f ms each on average (%.1f a second): CPU %.0f%%, RSP graphics %.0f%%, audio %.0f%% of the time'
          % (len(rows), span / len(rows) / CLK * 1000, len(rows) / (span / CLK), 100.0 * tot['cpu'] / span,
             100.0 * tot['gfx'] / span, 100.0 * tot['audio'] / span))


if __name__ == '__main__':
    main()
