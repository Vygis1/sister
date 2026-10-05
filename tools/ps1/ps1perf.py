"""Where the PlayStation core's time goes, read off the board.

    python tools/ps1/ps1perf.py              one reading
    python tools/ps1/ps1perf.py compare      with each cache switched off, for control

The counters live in rtl/ps1_top.v (perf[0..13]); console ctrl 0xEC selects one
in its low bits and reads it back, and bits 8..11 switch off the instruction
cache, the data cache, the cache self-check and the one-instruction-per-clock
path respectively. Switching a thing off and measuring again at the same point
in the BIOS is the only honest way to say what it was worth -- every time this
session guessed instead, the guess was wrong.
"""
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "pc"))
import fpgalink as fl

N = 0x0008_0000
BOARD = fl.DEFAULT_HOST

# 32..35 are the rasteriser's own: pixel pairs out, clocks busy, waiting for the
# pixel underneath, loading a palette. Read them with: python tools/ps1/ps1perf.py raster
NAMES = ["clocks", "memory transactions", "CPU held up", "instructions",
         "DMA owned the bus", "VRAM cache misses", "CPU cache misses",
         "drawing engine busy", "clocks in the slow fetch step",
         "clocks waiting for an instruction", "loads", "stores",
         "clocks collecting loads", "clocks on stores",
         "video cache waiting for a line", "memory refused a request"]

OFF = {"instruction cache": 1 << 8, "data cache": 1 << 9,
       "one instruction per clock": 1 << 11}


def snap(link, mode):
    out = []
    for i in range(len(NAMES)):
        link.write(N + 0xEC, i | (mode << 8))
        out.append(link.read(N + 0xEC))
    return out


def measure(link, mode=0, window=2.0):
    link.write(N + 0xEC, mode << 8)
    time.sleep(0.4)
    a = snap(link, mode)
    t0 = time.time()
    time.sleep(window)
    b = snap(link, mode)
    dt = time.time() - t0
    d = [(y - x) & 0xFFFFFFFF for x, y in zip(a, b)]
    return d, dt


def report(d, dt):
    clk = d[0] or 1
    ins = d[3] or 1
    print("  window %.2f s, %.1f M clocks" % (dt, clk / 1e6))
    for i in range(1, len(NAMES)):
        print("  %-34s %10d  %6.2f%% of clocks  %5.3f per instruction"
              % (NAMES[i], d[i], 100.0 * d[i] / clk, float(d[i]) / ins))
    print("  %.3f instructions per clock -> %.1f MIPS   (the console's own is 33.9)"
          % (d[3] / float(clk), d[3] / dt / 1e6))


if __name__ == "__main__":
    link = fl.Link(BOARD, 5005, timeout=0.5, retries=4)
    if len(sys.argv) > 1 and sys.argv[1] == "compare":
        print(" the console's own processor does 33.9 MIPS at 1 instruction per clock")
        rows = [("everything on", 0)] + [(("no " + k), v) for k, v in OFF.items()]
        rows.append(("everything on again", 0))
        for name, mode in rows:
            d, dt = measure(link, mode)
            clk = d[0] or 1
            ins = d[3] or 1
            print("  %-28s %5.1f MIPS  %.2f clocks each | loads %.2f, stores %.2f"
                  % (name, d[3] / dt / 1e6, clk / float(ins),
                     d[12] / float(ins), d[13] / float(ins)))
        link.write(N + 0xEC, 0)
    elif len(sys.argv) > 1 and sys.argv[1] == "raster":
        import time as _t
        def snap4():
            o = {}
            for i in (0, 32, 33, 34, 35):
                link.write(N + 0xEC, i); o[i] = link.read(N + 0xEC)
            return o
        a = snap4(); t0 = _t.time(); _t.sleep(2.0); b = snap4(); dt = _t.time() - t0
        clk = (b[0] - a[0]) & 0xFFFFFFFF or 1
        pairs = (b[32] - a[32]) & 0xFFFFFFFF
        busy = (b[33] - a[33]) & 0xFFFFFFFF
        print("  %.1f M clocks in %.1f s" % (clk / 1e6, dt))
        print("  pixel pairs written   %9d  (%.2f million pixels a second)" % (pairs, pairs * 2 / dt / 1e6))
        print("  rasteriser busy       %9d  %5.1f%% of clocks" % (busy, 100.0 * busy / clk))
        if busy: print("  -> %.2f clocks a pixel pair while busy (2 pixels a clock is the peak)" % (float(busy) / (pairs or 1)))
        print("  waiting for the pixel underneath %6d  %4.1f%%" % ((b[34]-a[34]) & 0xFFFFFFFF, 100.0*((b[34]-a[34]) & 0xFFFFFFFF)/clk))
        print("  loading a palette                %6d  %4.1f%%" % ((b[35]-a[35]) & 0xFFFFFFFF, 100.0*((b[35]-a[35]) & 0xFFFFFFFF)/clk))
    else:
        d, dt = measure(link)
        report(d, dt)
