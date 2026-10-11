"""texstall.py - the raster's texel fetches on the board (debug image t62+, over JTAG): how many,
how long they take, and how long the pipeline waits for them, over a window of seconds.

    python tools/ps1/texstall.py [SECONDS]

perf_sel 24 fetches, 25 their summed latency (clocks, issue to answer), 26 clocks the pipeline
waited for a texel line, 27 pairs through stage C, 28 the worst single fetch (since reset),
29 run lines taken, 30 lines dropped by writes {engine's [31:16], own [15:0]}, 31 conflict evictions.
"""
import os, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..')); sys.path.insert(0, HERE)
from jtag import Jtag
import ps1suite
N = 0x80000
P = ps1suite.PACE


def main():
    secs = float(sys.argv[1]) if len(sys.argv) > 1 else 10.0
    j = Jtag()
    def snap():
        out = []
        for k in (24, 25, 26, 27, 28, 29, 30, 31):
            j.write(N + 0xEC, P | k); out.append(j.read(N + 0xEC))
        return out
    a = snap(); t0 = time.time(); time.sleep(secs); b = snap(); dt = time.time() - t0
    j.write(N + 0xEC, P); j.close()
    d = [(y - x) & 0xFFFFFFFF for x, y in zip(a[:4], b[:4])]
    n, lat, wait, pairs = d
    clk = 50e6 * dt
    print('over %.1f s:' % dt)
    print('  texel fetches      %9d  (%.4f a textured pair, %d pairs)' % (n, n / max(1, pairs), pairs))
    print('  latency            %9.1f clocks a fetch on average, worst %d' % (lat / max(1, n), b[4]))
    print('  pipeline waiting   %9d clocks = %.1f%% of all clocks' % (wait, 100.0 * wait / clk))
    off = (b[5] - a[5]) & 0xFFFFFFFF
    inv_e = ((b[6] >> 16) - (a[6] >> 16)) & 0xFFFF; inv_w = ((b[6] & 0xFFFF) - (a[6] & 0xFFFF)) & 0xFFFF
    ev = (b[7] - a[7]) & 0xFFFFFFFF
    print('  run lines taken    %9d' % off)
    print('  lines dropped      %9d by the engine (fills/copies/uploads), %d by our own pixels (16-bit, wraps)' % (inv_e, inv_w))
    print('  conflict evictions %9d' % ev)


if __name__ == '__main__':
    main()
