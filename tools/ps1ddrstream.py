"""Turn the DDR3 frame path on or off, and see which one is running.

    python tools/ps1ddrstream.py on      stream from the DDR3 copy
    python tools/ps1ddrstream.py off     stream straight off the scanout
    python tools/ps1ddrstream.py         say which it is

The scanout used to feed the network directly, which tied the two together:
the network drains slowly, so the scanout stalled waiting for it, so reading
one picture took long enough that the machine drew the next frame into the
screen half way through -- the top of the picture from one frame and the bottom
from the next. With this on, a whole frame is captured into DDR3 at memory
speed and the network reads that still copy at its own pace.

Bit 27 of the stream control register (console ctrl 0xF0). The bit is a switch
rather than a rewrite because the direct path works, and getting this wrong has
stopped the machine before.
"""
import sys
sys.path.insert(0, r"C:/fpga/pc")
import fpgalink as fl

N = 0x0008_0000
CTL = N + 0xF0
BIT = 1 << 27


def main():
    link = fl.Link("192.168.178.50", 5005, timeout=0.6, retries=3)
    ctl = link.read(CTL)
    if len(sys.argv) > 1:
        want = sys.argv[1].lower() in ("on", "1", "ddr", "yes")
        new = (ctl | BIT) if want else (ctl & ~BIT)
        link.write(CTL, new)
        ctl = link.read(CTL)
    print("stream control %08x" % ctl)
    print("the frame comes from:", "the DDR3 copy" if (ctl & BIT) else "the scanout, directly")
    print("  streaming enabled :", bool(ctl & (1 << 31)))


if __name__ == "__main__":
    main()
