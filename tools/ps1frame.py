"""Where in a frame the drawing engine is busy, and what reading the screen costs.

    python tools/ps1frame.py

The picture tears because the machine redraws the screen while the screen is
being read. Two things decide whether that is fixable and how:

  the busy profile   sixteen counters across one frame. If some stretch of the
                     frame is quiet every time, that is where a capture belongs.
                     If none is, capture timing is dead and the read itself has
                     to get faster.
  the read cost      how many clocks a whole read of the screen takes, and how
                     many of those it spends stopped because whoever is taking
                     the pixels is full. Those want opposite fixes.
"""
import sys, time
sys.path.insert(0, r"C:/fpga/pc")
import fpgalink as fl
FLAGS = 0x3000 if 'fast' in sys.argv[1:] else 0
sys.argv = [a for a in sys.argv if a != 'fast']

N = 0x0008_0000
BOARD = "192.168.178.50"
HZ = 50e6


def main():
    link = fl.Link(BOARD, 5005, timeout=0.6, retries=3)

    def rd(sel):
        link.write(N + 0xEC, sel | FLAGS)
        return link.read(N + 0xEC)

    sels = [29, 30, 31, 48, 49, 50, 51, 52, 53, 7, 0] + list(range(32, 48))
    a = {s: rd(s) for s in sels}
    time.sleep(2.0)
    b = {s: rd(s) for s in sels}
    d = {s: (b[s] - a[s]) & 0xFFFFFFFF for s in sels}

    frames = d[49] or 1
    flen = b[48] or 1
    print("  %d frames in 2 s   frame length %d clocks (%.2f ms, %.1f Hz)"
          % (frames, flen, flen / HZ * 1e3, HZ / flen))
    print("  reading the screen: %6.0f clocks a frame (%.2f ms)  -- %.0f%% of a frame"
          % (d[29] / frames, d[29] / frames / HZ * 1e3, 100.0 * d[29] / frames / flen))
    print("     of which stopped, queue full: %6.0f (%.0f%%)"
          % (d[30] / frames, 100.0 * d[30] / (d[29] or 1)))
    print("     asking VRAM %.0f   waiting for VRAM %.0f   handing out pixels %.0f   waiting on the cache %.0f"
          % (d[50] / frames, d[51] / frames, d[52] / frames, d[53] / frames))
    print("  last whole capture, asked to ready: %d clocks (%.2f ms)"
          % (b[31], b[31] / HZ * 1e3))

    print("\n  drawing engine busy, across one frame (each bar is a sixteenth):")
    bins = [d[32 + k] for k in range(16)]
    width = (flen >> 4) * frames or 1
    for k, v in enumerate(bins):
        pct = 100.0 * v / width
        print("    %2d..%2d%%  %5.1f%%  %s" % (k * 100 // 16, (k + 1) * 100 // 16,
                                               pct, "#" * int(pct / 2.5)))
    quiet = [k for k, v in enumerate(bins) if 100.0 * v / width < 50.0]
    print("\n  quiet sixteenths (engine under half busy):", quiet if quiet else "none")


if __name__ == "__main__":
    main()
