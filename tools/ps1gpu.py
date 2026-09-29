"""The drawing engine against the real chip, measured properly.

    python tools/ps1gpu.py [seconds]      default 5

A real PlayStation GPU does about 53 Mpixels/s flat fill, roughly one pixel a
clock at 53 MHz. This prints where ours stands and where each clock goes, over
a window long enough to be honest: the BIOS has idle stretches where the engine
drops to ~47% busy, and a two-second sample landing in one reports a number that
looks like a fix and is not. It happened twice in one day. Five seconds, and
believe nothing unless `busy` is near where it was before.
"""
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pc"))
import fpgalink as fl
# ctrl 0xEC: 'pace' on the command line holds the CPU to the console's clock
# (bit 12; the default is the board's), 'fast' lets the GPU past its fill rate (bit 13)
FLAGS = (0x1000 if 'pace' in sys.argv[1:] else 0) | (0x2000 if 'fast' in sys.argv[1:] else 0)
sys.argv = [a for a in sys.argv if a not in ('fast', 'pace')]

N = 0x0008_0000
SEL = {"clk": 0, "ins": 3, "busy": 7, "px": 16, "scan": 17, "texelw": 18,
       "clutw": 19, "blendw": 20, "writew": 21, "prims": 22, "gradw": 23, "frames": 49}


def main():
    secs = float(sys.argv[1]) if len(sys.argv) > 1 else 5.0
    link = fl.Link(fl.DEFAULT_HOST, 5005, timeout=1.0, retries=4)

    def snap():
        o = {}
        for k, i in SEL.items():
            link.write(N + 0xEC, i | FLAGS); o[k] = link.read(N + 0xEC)
        return o

    a = snap(); t0 = time.time(); time.sleep(secs); b = snap(); dt = time.time() - t0
    d = {k: (b[k] - a[k]) & 0xFFFFFFFF for k in a}
    px = d["px"] or 1; busy = d["busy"]; clk = d["clk"] or 1; f = d["frames"] or 1
    cpp = busy / float(px)
    print("  over %.1f s:  CPU %.1f MIPS   engine %.1f%% busy   %d px/frame"
          % (dt, d["ins"] / dt / 1e6, 100.0 * busy / clk, px / f))
    print("  %.2f clocks/pixel  =  %.1f Mpixels/s     (real PS1: ~53, one a clock)"
          % (cpp, px / dt / 1e6))
    # the raster (ps1_raster.v): busy clocks, and what it was held for
    print("  raster clocks per pixel %.2f:  held for texel line %.2f   palette load %.2f   destination line %.2f   block queue %.2f"
          % (d["scan"] / float(px), d["texelw"] / float(px), d["clutw"] / float(px),
             d["blendw"] / float(px), d["writew"] / float(px)))
    if d["prims"]:
        print("  %d primitives: %.0f raster clocks each, %.0f gradient set-up clocks each"
              % (d["prims"], d["scan"] / float(d["prims"]), d["gradw"] / float(d["prims"])))
    print("  frame budget: engine uses %d of %d clocks a frame (%.0f%%); a clean capture needs it under ~50%%"
          % (busy / f, clk / f, 100.0 * busy / clk))


if __name__ == "__main__":
    main()
