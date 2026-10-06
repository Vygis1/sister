"""ps1load.py - what bounds the PlayStation core's frame rate, second by second, read through
pc/pad.py's tool port (the ESP32 link; never the LAN).

    python tools/ps1/ps1load.py [SECONDS]

Each second: display flips (console 0x6C), and from the core's counters (rtl/ps1_top.v
perf[], selected through console 0xEC -- only the index is written, the mode bits stay
at their defaults): the share of clocks the drawing engine was busy, the CPU was held
up, and the CPU's instructions a clock. A second under 30 flips with the engine near
100% is the GPU's; with the engine idle, the CPU's (or a load).
"""
import socket
import sys
import time

f = socket.create_connection(('127.0.0.1', 5557), timeout=5).makefile('rwb')
N = 0x00080000


def rd(a):
    f.write(b'R %08x\n' % a); f.flush()
    return int(f.readline().split()[-1], 16)


def wr(a, v):
    f.write(b'W %08x %08x\n' % (a, v)); f.flush(); f.readline()


def ctr(i):
    wr(N + 0xEC, i)
    return rd(N + 0xEC)


def counters():
    return {k: ctr(i) for k, i in (('clk', 0), ('held', 2), ('ins', 3), ('gpu', 7))}


secs = int(sys.argv[1]) if len(sys.argv) > 1 else 30
last = rd(N + 0x6C) & 0x7FFFF
c0 = counters()
print(' s  flips  gpu%  held%  ipc')
for s in range(secs):
    t0 = time.time()
    flips = 0
    while time.time() - t0 < 1.0:
        d = rd(N + 0x6C) & 0x7FFFF
        if d != last:
            flips += 1
            last = d
    c1 = counters()
    dc = {k: (c1[k] - c0[k]) & 0xFFFFFFFF for k in c1}
    c0 = c1
    clk = max(dc['clk'], 1)
    print('%2d  %5d  %4.0f  %5.0f  %4.2f' % (s, flips, 100.0 * dc['gpu'] / clk, 100.0 * dc['held'] / clk, dc['ins'] / clk))
