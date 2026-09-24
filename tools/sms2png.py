"""Turn a Master System frame dump into a PNG.

    python tools/sms2png.py build/sms_sim.txt build/sms_sim.png

The file holds the VDP's own 6-bit --BBGGRR colours rather than palette
indices, because unlike the NES the palette belongs to the game: there is no
fixed table this script could look anything up in.
"""
import sys, zlib, struct

rows = [l.strip() for l in open(sys.argv[1]) if l.strip()]
W = max(len(r) // 2 for r in rows)
H = len(rows)

def expand(two):          # 2 bits to 8, so 3 becomes full white not 3/255
    return (two * 85) & 0xFF

raw = b""
for r in rows:
    line = b"\x00"
    for x in range(W):
        c = int(r[x*2:x*2+2], 16) if x*2+2 <= len(r) else 0
        line += bytes([expand(c & 3), expand((c >> 2) & 3), expand((c >> 4) & 3)])
    raw += line

def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data)))

png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw, 9))
       + chunk(b"IEND", b""))
open(sys.argv[2], "wb").write(png)
print(f"{sys.argv[2]}: {W}x{H}")
