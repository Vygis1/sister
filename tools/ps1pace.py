"""The speed knob: the console's pace, or the board's.

    python tools/ps1pace.py              show the setting
    python tools/ps1pace.py original     CPU at 33.8688 MHz, GPU at the chip's fill rate (the default)
    python tools/ps1pace.py fast         CPU at 50 MHz, GPU two pixels a clock whatever the pixel
    python tools/ps1pace.py cpu-fast     just the CPU past the console's pace
    python tools/ps1pace.py gpu-fast     just the GPU

The knob is ctrl register 0xEC of the console page: bit 12 lets the CPU run on
every 50 MHz clock instead of 33.8688 of every 50 million, bit 13 lets the
rasteriser land textured, shaded and blended pixels two a clock instead of at
the 53.2 MHz chip's one a clock (see ps1_top.v and ps1_raster.v). Bits 8..11
are the cache/overlap debug switches and are left alone; bits 5..0 pick the
performance counter and are left alone too.

The measuring tools (ps1gpu.py, ps1cpu.py, ...) rewrite this register on every
sample; give them 'fast' on their command line to keep the knob at fast while
they measure.
"""
import sys
sys.path.insert(0, "pc")
import fpgalink as fl

N = 0x0008_0000
CPU_FAST, GPU_FAST = 1 << 12, 1 << 13


def main():
    link = fl.Link("192.168.178.50", 5005, timeout=1.0, retries=4)
    # the register reads back as the selected performance counter, not as
    # itself, so the flag bits are kept here and written whole
    want = {"original": 0, "fast": CPU_FAST | GPU_FAST, "cpu-fast": CPU_FAST, "gpu-fast": GPU_FAST}
    if len(sys.argv) > 1:
        if sys.argv[1] not in want:
            sys.exit(__doc__)
        link.write(N + 0xEC, want[sys.argv[1]])
        print("set:", sys.argv[1])
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
