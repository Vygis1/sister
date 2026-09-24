"""Turn a framebuffer read off the board (RGB332, one byte per pixel) into a PNG.

    python tools/fb2png.py build/hw_a.bin build/hw_a.png
"""
import sys, zlib, struct

src, dst = sys.argv[1], sys.argv[2]
d = open(src, "rb").read()
# The buffer is 320 wide whatever is running; a narrower machine leaves the rest
# of each row alone, so crop rather than show 320 of everything.
#
#   tools/fb2png.py in.bin out.png [width] [height]
STRIDE = 320
W = int(sys.argv[3]) if len(sys.argv) > 3 else STRIDE
H = int(sys.argv[4]) if len(sys.argv) > 4 else len(d) // STRIDE
raw = bytearray()
for y in range(H):
    raw.append(0)
    for x in range(W):
        v = d[y * STRIDE + x]
        raw += bytes([round((v >> 5) * 255 / 7),
                      round(((v >> 2) & 7) * 255 / 7),
                      round((v & 3) * 255 / 3)])

def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

open(dst, "wb").write(b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    + chunk(b"IEND", b""))
print(f"{dst}: {W}x{H}")
