"""Save what the web page is showing as a PNG, so it can be looked at.

    python tools/ps1shot.py [out.png]

The frame comes over as RGB555, two bytes a pixel, little endian, which is what
the console's VRAM holds. No image library needed: a PNG is a zlib stream of
rows, each with a filter byte, and four CRC'd chunks around it.
"""
import os, sys, zlib, struct, urllib.request

SERVER = "http://127.0.0.1:8080"


def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "console", "screen.png")
    r = urllib.request.urlopen(SERVER + "/api/vid/frame", timeout=10)
    b = r.read()
    w = int(r.headers.get("X-Width", 320))
    h = int(r.headers.get("X-Height", 240))
    if w * h * 2 > len(b):
        h = len(b) // (2 * w)

    rows = bytearray()
    for y in range(h):
        rows.append(0)                       # filter: none
        base = y * w * 2
        for x in range(w):
            p = b[base + x * 2] | (b[base + x * 2 + 1] << 8)
            # RGB555 -> 8 bits a channel, low bits carried down so white is white
            rd = (p & 31) << 3
            gn = ((p >> 5) & 31) << 3
            bl = ((p >> 10) & 31) << 3
            rows += bytes((rd | rd >> 5, gn | gn >> 5, bl | bl >> 5))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(rows), 6))
           + chunk(b"IEND", b""))
    open(out, "wb").write(png)
    lit = sum(1 for k in range(0, len(b), 2) if b[k:k + 2] != b"\x00\x00")
    print("%s  %dx%d  %d of %d pixels lit" % (out, w, h, lit, w * h))


if __name__ == "__main__":
    main()
