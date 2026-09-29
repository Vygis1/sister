"""The speed knob: the console's pace, or the board's.

    python tools/ps1pace.py              show the setting
    python tools/ps1pace.py original     CPU at 33.8688 MHz, GPU at the chip's fill rate
    python tools/ps1pace.py fast         CPU at 50 MHz, GPU two pixels a clock whatever the pixel
    python tools/ps1pace.py cpu-fast     just the CPU past the console's pace (the default)
    python tools/ps1pace.py gpu-fast     just the GPU

The knob is ctrl register 0xEC of the console page: bit 12 holds the CPU to
33.8688 of every 50 million clocks instead of every 50 MHz clock (clear, the
default, since 2026-09-28: this CPU takes three clocks for a load where the
R3000 takes one, and at the console's clock Crash's levels ran at 20 fps where
the console's run at 30; the timers, video and sound keep the console's clock
either way), bit 13 lets the
rasteriser land textured, shaded and blended pixels two a clock instead of at
the 53.2 MHz chip's one a clock (see ps1_top.v and ps1_raster.v). Bits 8..11
are the cache/overlap debug switches and are left alone; bits 5..0 pick the
performance counter and are left alone too.

The measuring tools (ps1gpu.py, ps1cpu.py, ...) rewrite this register on every
sample; give them 'pace' (CPU at the console's clock) and/or 'fast' (GPU past
its fill rate) on their command line to keep those while they measure.
"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pc"))
import fpgalink as fl

N = 0x0008_0000
CPU_PACE, GPU_FAST = 1 << 12, 1 << 13


def main():
    link = fl.Link(fl.DEFAULT_HOST, 5005, timeout=1.0, retries=4)
    # the register reads back as the selected performance counter, not as
    # itself, so the flag bits are kept here and written whole
    want = {"original": CPU_PACE, "fast": GPU_FAST, "cpu-fast": 0, "gpu-fast": CPU_PACE | GPU_FAST}
    if len(sys.argv) > 1:
        if sys.argv[1] not in want:
            sys.exit(__doc__)
        link.write(N + 0xEC, want[sys.argv[1]])
        print("set:", sys.argv[1])
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
