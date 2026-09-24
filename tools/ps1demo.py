"""The boot screen our PlayStation draws, in R3000 machine code.

    python tools/ps1demo.py sim/roms/ps1/boot.hex

There is no Sony BIOS on this machine, and the Sony boot menu IS the BIOS -- so
until one is dropped in, this is what the PlayStation shows: a program that runs
on the real R3000 and draws through the real GPU, so that "PlayStation on the
dashboard" means the silicon we built is putting a picture on the screen.

It does what a boot animation does with the parts that exist: clears the screen
to a vertical gradient (a full-screen Gouraud quad), draws a diamond of four
Gouraud triangles in the middle, lays a row of flat rectangles beneath it like a
menu bar, turns the display on, and then loops forever polling the frame counter
so the machine is visibly alive rather than halted.

Every GP0/GP1 write goes straight to the register at $1F801810/$1F801814, paced
by GPUSTAT bit 26 (ready for a command). No DMA, no interrupts: the smallest
thing that is unmistakably a PlayStation drawing.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mipsasm import *                                        # noqa: E402

GP0    = 0x1F801810
GP1    = 0x1F801814        # GPUSTAT on read
STACK  = 0x001FFF00


def rgb(r, g, b):
    return (b << 16) | (g << 8) | r


def xy(x, y):
    return ((y & 0xFFFF) << 16) | (x & 0xFFFF)


class Demo:
    def __init__(self):
        self.a = Asm(org=0xBFC00000)
        self.stream = []          # (kind, word) with kind 'gp0' or 'gp1'

    def gp0(self, hdr, *args):
        self.stream.append(('gp0', hdr & 0xFFFFFFFF, [a & 0xFFFFFFFF for a in args]))
    def gp1(self, w):
        self.stream.append(('gp1', w & 0xFFFFFFFF, []))

    def scene(self):
        # environment
        self.gp0(0xE1000200 | 0x0008)         # texpage, 15-bit (unused, but sane)
        self.gp0(0xE3000000)                  # draw area top-left 0,0
        self.gp0(0xE4000000 | 319 | (239 << 10))   # .. bottom-right 319,239
        self.gp0(0xE5000000)                  # offset 0,0

        # background: two flat fills (the fast $02 fill, whole command at once)
        self.gp0(0x02000000 | rgb(8, 12, 40), xy(0, 0),   xy(320, 240))   # deep blue
        self.gp0(0x02000000 | rgb(2, 2, 8),   xy(0, 144), xy(320, 96))    # near black below

        # a diamond in the middle: four Gouraud triangles from the centre out,
        # each edge a different bright colour so the interpolation is obvious
        cx, cy, r = 160, 110, 60
        pts = [(cx, cy - r, rgb(255, 80, 40)),   # top    - orange
               (cx + r, cy, rgb(255, 220, 40)),  # right  - yellow
               (cx, cy + r, rgb(40, 200, 255)),  # bottom - cyan
               (cx - r, cy, rgb(180, 80, 255))]  # left   - violet
        centre = rgb(255, 255, 255)
        for i in range(4):
            x0, y0, c0 = pts[i]
            x1, y1, c1 = pts[(i + 1) % 4]
            self.gp0(0x30000000 | (centre & 0xFFFFFF), xy(cx, cy),
                     c0 & 0xFFFFFF, xy(x0, y0), c1 & 0xFFFFFF, xy(x1, y1))

        # a menu bar: five flat rectangles beneath the diamond
        cols = [rgb(200, 60, 60), rgb(200, 140, 40), rgb(220, 200, 40),
                rgb(60, 200, 90), rgb(60, 120, 220)]
        for i, c in enumerate(cols):
            x = 40 + i * 50
            self.gp0(0x60000000 | (c & 0xFFFFFF), xy(x, 200), xy(40, 24))

        # display on: 320x240 from VRAM (0,0)
        self.gp1(0x05000000)                  # display area = 0,0
        self.gp1(0x07000000 | (16) | (256 << 10))   # vertical range
        self.gp1(0x08000001)                  # 320x240, 15-bit, NTSC
        self.gp1(0x03000000)                  # display enabled

    def build(self):
        a = self.a
        # reset lands at $BFC00000. Set up a stack and the two port addresses.
        a.li(SP, STACK)
        a.li(S0, GP0)                         # GP0/GPUREAD
        a.li(S1, GP1)                         # GP1/GPUSTAT
        self.scene()

        for kind, hdr, args in self.stream:
            if kind == 'gp0':
                # Wait until the GPU is fully idle (bit 26), THEN push the whole
                # command -- header and every argument -- back to back. A command
                # is at most nine words and the FIFO is sixteen deep, so it never
                # overflows, and the engine never stalls mid-command waiting for
                # an argument the CPU is too busy polling to send.
                lbl = self._lbl('wait')
                a.label(lbl)
                a.lw(T0, 0, S1); a.nop()
                a.lui(T1, 0x0400)            # bit 26 = ready for a command
                a.and_(T0, T0, T1)
                a.beq(T0, ZERO, lbl)
                a.nop()
                a.li(T2, hdr); a.sw(T2, 0, S0)
                for w in args:
                    a.li(T2, w); a.sw(T2, 0, S0)
            else:
                a.li(T2, hdr); a.sw(T2, 0, S1)

        # alive: read GPUSTAT forever so the PC is visibly not stuck on a store
        a.label('spin')
        a.lw(T0, 0, S1)
        a.j('spin'); a.nop()

        self._n = 0
        return a.words()

    def _lbl(self, base):
        n = getattr(self, '_c', 0); self._c = n + 1
        return f'{base}_{n}'


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else 'sim/roms/ps1/boot.hex'
    words = Demo().build()
    os.makedirs(os.path.dirname(out) or '.', exist_ok=True)
    write_hex(words, out)
    print('%s: %d words (%d bytes)' % (out, len(words), len(words) * 4))


if __name__ == '__main__':
    main()
