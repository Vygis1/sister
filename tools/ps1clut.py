"""What palette is the machine actually drawing with?

    python tools/ps1clut.py [samples]        default 40

The Crash logo comes out white with magenta wedges where DuckStation, same BIOS
and same disc, shows it solid yellow (see the emulator note in memory). Yellow
is red+green, white is red+green+blue and magenta is red+blue, so blue is
arriving where it should not be and green is being lost. That is either the
palette in video memory being wrong -- the upload -- or the fetch reading the
wrong entries.

This settles which. It walks the display list the DMA is actually feeding the
drawing engine, pulls the palette address and the colour depth out of every
textured primitive, and then reads those palettes straight out of video memory
and prints them as colours. If the palette in memory is yellow, the upload is
fine and the fetch is wrong; if the palette itself is white and magenta, the
fault is upstream in the upload or the disc path.

The machine is HALTED while this reads (ctrl 0x04 bit 2), so the display list,
the palette and the picture on the page are all the same moment. Do not use
bit 0 for this: bit 0 is the core's RESET (`core_rst = rst || !run`), and a tool
that "stops the processor" with it is reading a machine that has been reset.
"""
import sys, collections
sys.path.insert(0, r"C:/fpga/pc")
import fpgalink as fl

N = 0x0008_0000
RAM_LINE = 0x10000
BOARD = "192.168.178.50"

# command -> (words, index of the first UV word, index of the second UV word)
# A shaded textured polygon carries its PALETTE in the top half of the first UV
# word and its TEXTURE PAGE in the top half of the second.
TEX = {
    0x24: (7, 2, 4),  0x25: (7, 2, 4),  0x26: (7, 2, 4),  0x27: (7, 2, 4),
    0x2C: (9, 2, 4),  0x2D: (9, 2, 4),  0x2E: (9, 2, 4),  0x2F: (9, 2, 4),
    0x34: (9, 2, 5),  0x36: (9, 2, 5),
    0x3C: (12, 2, 5), 0x3E: (12, 2, 5),
    0x64: (4, 2, None), 0x65: (4, 2, None), 0x66: (4, 2, None), 0x67: (4, 2, None),
    0x74: (3, 2, None), 0x75: (3, 2, None), 0x7C: (3, 2, None), 0x7D: (3, 2, None),
}
DEPTH = {0: "4-bit (16 colours)", 1: "8-bit (256 colours)", 2: "15-bit (no palette)", 3: "reserved"}


def main():
    samples = int(sys.argv[1]) if len(sys.argv) > 1 else 40
    l = fl.Link(BOARD, 5005, timeout=1.0, retries=4)
    run0 = l.read(N + 0x04)
    l.write(N + 0x04, run0 | 4)          # halt: everything below is one moment

    def rdline(line, cache):
        if line in cache:
            return cache[line]
        l.write(N + 0x7C, line)
        for _ in range(60):
            if l.read(N + 0x7C) >> 31:
                break
        v = [l.read(N + 0x80 + 4 * k) for k in range(4)]
        cache[line] = v
        return v

    def ram_words(a, n, cache):
        out = []
        while len(out) < n:
            addr = a + 4 * len(out)
            out += rdline(RAM_LINE + (addr >> 4), cache)[(addr >> 2) & 3:]
        return out[:n]

    def vram_px(x, y, cache):
        """One 16-bit pixel out of video memory. A line is eight pixels."""
        v = rdline((y * 128) + (x >> 3), cache)
        w = v[(x >> 1) & 3]
        return (w >> 16) & 0xFFFF if (x & 1) else (w & 0xFFFF)

    seen = collections.Counter()      # (clut, depth) -> how many primitives used it
    ops = collections.Counter()
    for _ in range(samples):
        cache = {}
        l.write(N + 0x118, 1)
        for _ in range(200):
            if not (l.read(N + 0x118) & 1):
                break
        for i in range(16):
            l.write(N + 0x90, i)
            a = l.read(N + 0x90) & 0xFFFFFF
            hdr = l.read(N + 0x94)
            n = hdr >> 24
            if not (0 < n <= 16):
                continue
            ws = ram_words(a + 4, n, cache)
            op = ws[0] >> 24
            ops[op] += 1
            if op not in TEX:
                continue
            need, uv0, uv1 = TEX[op]
            if n < need:
                continue
            clut = ws[uv0] >> 16
            tpage = (ws[uv1] >> 16) if uv1 is not None and n > uv1 else None
            depth = ((tpage >> 7) & 3) if tpage is not None else None
            seen[(clut, depth)] += 1

    print("commands in the list: " + "  ".join("%02x x%d" % (o, c) for o, c in ops.most_common(12)))
    if not seen:
        print("no textured primitives were sampled -- try again, or on a screen with textures")
        return
    print()
    cache = {}
    for (clut, depth), count in seen.most_common(6):
        cx = (clut & 0x3F) * 16
        cy = (clut >> 6) & 0x1FF
        ncol = 16 if depth == 0 else (256 if depth == 1 else 0)
        print("palette at vram (%d,%d), %s, used by %d sampled primitives"
              % (cx, cy, DEPTH.get(depth, "?"), count))
        if ncol == 0:
            print("   (no palette: the texture is direct colour)")
            continue
        shown = min(ncol, 16)
        for k in range(shown):
            p = vram_px(cx + k, cy, cache)
            r, g, b = p & 31, (p >> 5) & 31, (p >> 10) & 31
            name = ""
            if r > 20 and g > 20 and b > 20: name = "WHITE"
            elif r > 20 and g > 20 and b < 10: name = "yellow"
            elif r > 20 and b > 20 and g < 10: name = "MAGENTA"
            elif g > 20 and b > 20 and r < 10: name = "cyan"
            elif r > 20 and g < 10 and b < 10: name = "red"
            elif g > 20 and r < 10 and b < 10: name = "green"
            elif b > 20 and r < 10 and g < 10: name = "blue"
            elif r < 6 and g < 6 and b < 6: name = "black"
            print("   [%2d] %04x  r=%2d g=%2d b=%2d  %s" % (k, p, r, g, b, name))
        print()


if __name__ == "__main__":
    try:
        main()
    finally:
        # never leave the machine halted, whatever went wrong above
        try:
            ll = fl.Link(BOARD, 5005, timeout=1.0, retries=4)
            ll.write(N + 0x04, ll.read(N + 0x04) & ~4)
        except Exception:
            pass
