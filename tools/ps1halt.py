"""Stop the machine where it stands, and let it go again.

    python tools/ps1halt.py stop       hold the processor
    python tools/ps1halt.py go         let it run
    python tools/ps1halt.py            say which it is

ctrl 0x04 bit 2. This is NOT bit 0: bit 0 is the core's RESET
(`core_rst = rst || !run` in console_top.v), so clearing it to "pause" the
machine puts the CPU back at bfc00000, wipes what was being looked at and means
the disc has to be booted again. Every tool that claimed to freeze the machine
with bit 0 was reading a machine that had been reset; `tools/ps1shapes.py` still
does, and its output is not to be trusted until it is changed to use this.

With bit 2 set the processor holds, the drawing engine finishes what is queued
and goes quiet, video memory stops moving, and the scanout keeps running -- so
the page still shows the frozen picture, and the display list, the palettes, the
textures and the framebuffer can all be read and be CONSISTENT with each other
and with what is on the screen. That is the thing that was missing.
"""
import sys
sys.path.insert(0, r"C:/fpga/pc")
import fpgalink as fl

N = 0x0008_0000
BOARD = "192.168.178.50"


def link():
    return fl.Link(BOARD, 5005, timeout=1.0, retries=4)


def state(l):
    return l.read(N + 0x04)


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "show"
    l = link()
    c = state(l)
    if what in ("stop", "halt", "freeze"):
        l.write(N + 0x04, c | 4)
        c = state(l)
        print("halted (ctrl 0x04 = %08x), pc %08x" % (c, l.read(N + 0x14)))
    elif what in ("go", "run", "resume"):
        l.write(N + 0x04, c & ~4)
        c = state(l)
        print("running (ctrl 0x04 = %08x), pc %08x" % (c, l.read(N + 0x14)))
    else:
        print("ctrl 0x04 = %08x: run=%d halt=%d   pc %08x"
              % (c, c & 1, (c >> 2) & 1, l.read(N + 0x14)))


if __name__ == "__main__":
    main()
