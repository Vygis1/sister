"""Why is THIS pixel that colour? The machine, halted, answers.

    python tools/ps1pixel.py 120 40          one screen pixel
    python tools/ps1pixel.py 60 30 200 70    every primitive touching that box

Halts the processor (ctrl 0x04 bit 2 -- NOT bit 0, which is the core's reset),
lets the drawing engine drain, then reads ONE CONSISTENT MOMENT: the display
list out of RAM, the palettes and textures out of video memory, and the
framebuffer itself. Because nothing moves while it reads, the primitive, the
texels it names, the palette entry those index, and the pixel actually in the
framebuffer can all be put side by side.

That is the thing that has been missing. Until ctrl 0x04 bit 2 existed there was
no way to stop the machine without resetting it, so every "read the display list
and compare it with the screen" was comparing two different moments, and several
hours went into chasing the difference.

What it prints, for each primitive that covers the pixel:

    the command and its vertices        what the game asked for
    the texture page and palette        where it said to read colour from
    the texel at that pixel's u,v       what is actually in video memory there
    the palette entry it indexes        what colour that should become
    the pixel in the framebuffer        what the machine actually drew

A texel that reads zero where the emulator shows a letter means the texture is
not where we think it is. A palette entry that is yellow next to a framebuffer
pixel that is white means the fetch picked the wrong entry.
"""
import sys
sys.path.insert(0, r"C:/fpga/pc")
import fpgalink as fl

N = 0x0008_0000
RAM_LINE = 0x10000
BOARD = "192.168.178.50"

# op -> (words, vertex word indices, uv word indices)
POLY = {
    0x20: (4, [1, 2, 3], []),            0x22: (4, [1, 2, 3], []),
    0x28: (5, [1, 2, 3, 4], []),         0x2A: (5, [1, 2, 3, 4], []),
    0x24: (7, [1, 3, 5], [2, 4, 6]),     0x25: (7, [1, 3, 5], [2, 4, 6]),
    0x26: (7, [1, 3, 5], [2, 4, 6]),     0x27: (7, [1, 3, 5], [2, 4, 6]),
    0x2C: (9, [1, 3, 5, 7], [2, 4, 6, 8]), 0x2D: (9, [1, 3, 5, 7], [2, 4, 6, 8]),
    0x2E: (9, [1, 3, 5, 7], [2, 4, 6, 8]), 0x2F: (9, [1, 3, 5, 7], [2, 4, 6, 8]),
    0x30: (6, [1, 3, 5], []),            0x32: (6, [1, 3, 5], []),
    0x38: (8, [1, 3, 5, 7], []),         0x3A: (8, [1, 3, 5, 7], []),
    0x34: (9, [1, 4, 7], [2, 5, 8]),     0x36: (9, [1, 4, 7], [2, 5, 8]),
    0x3C: (12, [1, 4, 7, 10], [2, 5, 8, 11]), 0x3E: (12, [1, 4, 7, 10], [2, 5, 8, 11]),
}
# where the palette and the texture page live inside a textured primitive
CLUT_AT = {0x24: 2, 0x25: 2, 0x26: 2, 0x27: 2, 0x2C: 2, 0x2D: 2, 0x2E: 2, 0x2F: 2,
           0x34: 2, 0x36: 2, 0x3C: 2, 0x3E: 2}
TPAGE_AT = {0x24: 4, 0x25: 4, 0x26: 4, 0x27: 4, 0x2C: 4, 0x2D: 4, 0x2E: 4, 0x2F: 4,
            0x34: 5, 0x36: 5, 0x3C: 5, 0x3E: 5}
DEPTH = {0: "4-bit", 1: "8-bit", 2: "15-bit direct", 3: "reserved"}


def s11(v):
    v &= 0x7FF
    return v - 2048 if v & 0x400 else v


class Board(object):
    def __init__(self):
        self.l = fl.Link(BOARD, 5005, timeout=1.0, retries=4)
        self.cache = {}

    def halt(self):
        c = self.l.read(N + 0x04)
        self.l.write(N + 0x04, c | 4)
        # let the drawing engine drain, then make RAM current
        self.l.write(N + 0x118, 1)
        for _ in range(400):
            if not (self.l.read(N + 0x118) & 1):
                break
        self.cache = {}

    def go(self):
        c = self.l.read(N + 0x04)
        self.l.write(N + 0x04, c & ~4)

    def line(self, ln):
        if ln in self.cache:
            return self.cache[ln]
        self.l.write(N + 0x7C, ln)
        for _ in range(60):
            if self.l.read(N + 0x7C) >> 31:
                break
        v = [self.l.read(N + 0x80 + 4 * k) for k in range(4)]
        self.cache[ln] = v
        return v

    def ram(self, a, n):
        out = []
        while len(out) < n:
            ad = a + 4 * len(out)
            out += self.line(RAM_LINE + (ad >> 4))[(ad >> 2) & 3:]
        return out[:n]

    def px(self, x, y):
        w = self.line((y * 128) + (x >> 3))[(x >> 1) & 3]
        return (w >> 16) & 0xFFFF if (x & 1) else (w & 0xFFFF)


def rgb(p):
    return "%04x (r=%2d g=%2d b=%2d)%s" % (p, p & 31, (p >> 5) & 31, (p >> 10) & 31,
                                           "  TRANSPARENT" if (p & 0x7FFF) == 0 else "")


def texel(b, tpx, tpy, depth, u, v):
    """The palette INDEX (or the colour, for a direct texture) at (u,v)."""
    if depth == 0:
        w = b.px(tpx + (u >> 2), tpy + v)
        return (w >> (4 * (u & 3))) & 15
    if depth == 1:
        w = b.px(tpx + (u >> 1), tpy + v)
        return (w >> (8 * (u & 1))) & 255
    return b.px(tpx + u, tpy + v)


def main():
    a = [int(x) for x in sys.argv[1:]]
    if len(a) == 2:
        x0, y0, x1, y1 = a[0], a[1], a[0], a[1]
    elif len(a) == 4:
        x0, y0, x1, y1 = a
    else:
        print(__doc__)
        return
    b = Board()
    b.halt()
    try:
        draw = b.l.read(N + 0x70)
        disp = b.l.read(N + 0x6C)
        ofs_x = s11(draw & 0x7FF)
        ofs_y = s11((draw >> 11) & 0x7FF)
        print("halted at pc %08x.  draw reg %08x (offset %d,%d)  disp reg %08x"
              % (b.l.read(N + 0x14), draw, ofs_x, ofs_y, disp))
        print("looking for primitives covering screen box (%d,%d)-(%d,%d)" % (x0, y0, x1, y1))
        print()

        shown = 0
        for i in range(16):
            b.l.write(N + 0x90, i)
            addr = b.l.read(N + 0x90) & 0xFFFFFF
            # follow the ordering table from this node to the end
            seen = set()
            while addr and addr != 0xFFFFFF and addr not in seen and shown < 12:
                seen.add(addr)
                hdr = b.ram(addr, 1)[0]
                n = hdr >> 24
                nxt = hdr & 0xFFFFFF
                if not (0 < n <= 16):
                    break
                ws = b.ram(addr + 4, n)
                op = ws[0] >> 24
                if op in POLY:
                    need, vi, ui = POLY[op]
                    if n >= need:
                        xs = [s11(ws[k]) + ofs_x for k in vi]
                        ys = [s11(ws[k] >> 16) + ofs_y for k in vi]
                        if not (max(xs) < x0 or min(xs) > x1 or max(ys) < y0 or min(ys) > y1):
                            shown += 1
                            print("@%06x  op %02x  colour %06x" % (addr, op, ws[0] & 0xFFFFFF))
                            print("   corners on screen: " + "  ".join("(%d,%d)" % (p, q) for p, q in zip(xs, ys)))
                            if ui and op in TPAGE_AT and n > TPAGE_AT[op]:
                                clut = ws[CLUT_AT[op]] >> 16
                                tp = ws[TPAGE_AT[op]] >> 16
                                tpx, tpy, dep = (tp & 15) * 64, ((tp >> 4) & 1) * 256, (tp >> 7) & 3
                                cx, cy = (clut & 0x3F) * 16, (clut >> 6) & 0x1FF
                                uvs = [(ws[k] & 255, (ws[k] >> 8) & 255) for k in ui]
                                print("   uv: " + "  ".join("(%d,%d)" % uv for uv in uvs))
                                print("   texture page (%d,%d) %s ; palette at vram (%d,%d)"
                                      % (tpx, tpy, DEPTH.get(dep, "?"), cx, cy))
                                for u, v in uvs[:2]:
                                    t = texel(b, tpx, tpy, dep, u, v)
                                    if dep in (0, 1):
                                        print("      texel at u=%d v=%d -> index %d -> palette %s"
                                              % (u, v, t, rgb(b.px(cx + t, cy))))
                                    else:
                                        print("      texel at u=%d v=%d -> %s" % (u, v, rgb(t)))
                                if dep in (0, 1):
                                    ncol = 16 if dep == 0 else 256
                                    print("   palette: " + " ".join("%04x" % b.px(cx + k, cy)
                                                                    for k in range(min(16, ncol))))
                            print()
                addr = nxt
        if shown == 0:
            print("no primitive in the sampled list covers that box -- the list is sampled from")
            print("the sixteen nodes the DMA touched most recently, so try again")
        print("framebuffer at the box corner, straight out of video memory:")
        dx = disp & 0x3FF
        dy = (disp >> 12) & 0x1FF
        for y in range(y0, min(y1 + 1, y0 + 4)):
            print("   screen row %3d: " % y + " ".join("%04x" % b.px(dx + x, dy + y)
                                                       for x in range(x0, min(x1 + 1, x0 + 12))))
    finally:
        b.go()
        print()
        print("running again")


if __name__ == "__main__":
    main()
