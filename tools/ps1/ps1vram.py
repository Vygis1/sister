"""Dump the console's VRAM (1024x512 RGB555, DDR3 0..1 MB) as a PNG.
    python tools/ps1/ps1vram.py out.png [y0 y1]     rows y0..y1-1 (default all 512)
Flushes the VRAM cache first (ctrl 0xE0) so the dump is what the GPU sees.
"""
import os, sys, time, zlib, struct
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "pc"))
import fpgalink as fl
N = 0x0008_0000
def read_line(link, line):
    link.write(N + 0x7C, line)
    for _ in range(50):
        if link.read(N + 0x7C) >> 31: break
    return b"".join(link.read(N + 0x80 + 4 * k).to_bytes(4, "little") for k in range(4))
def main():
    out = sys.argv[1]; y0 = int(sys.argv[2]) if len(sys.argv) > 2 else 0; y1 = int(sys.argv[3]) if len(sys.argv) > 3 else 512
    link = fl.Link(fl.DEFAULT_HOST, 5005, timeout=1.0, retries=4)
    link.write(N + 0xE0, 1)
    for _ in range(200):
        if not (link.read(N + 0xE0) >> 31): break
    t0 = time.time(); raw = b""; lit = 0
    for y in range(y0, y1):
        row = b"".join(read_line(link, y * 128 + k) for k in range(128))
        line = bytearray([0])
        for x in range(1024):
            p = row[2 * x] | (row[2 * x + 1] << 8); lit += (p & 0x7FFF) != 0
            line += bytes(((p & 31) << 3, ((p >> 5) & 31) << 3, ((p >> 10) & 31) << 3))
        raw += bytes(line)
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    h = y1 - y0
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1024, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
    open(out, "wb").write(png)
    print("%s  1024x%d  %d pixels lit  (%.0f s)" % (out, h, lit, time.time() - t0))
if __name__ == "__main__":
    main()
