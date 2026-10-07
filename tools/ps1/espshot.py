"""espshot.py - the PlayStation's picture as the board shows it, without the network: the frame
fb_ddr keeps in DDR3 (640 x 240 RGB555, two pixels a word, row r at word r * 320), read
through regfile's pages 0x10-0x19 with the ESP32's block read (pc/pad.py's tool port, "D").

    python tools/ps1/espshot.py OUT.png [WIDTH [HEIGHT]]      (default 640 x 240; ~1 min)
"""
import socket
import sys
import zlib
import struct

FB = 0x100000


def read_block(f, addr, n):
    for attempt in range(4):                                 # (a reply cut short on the serial link: ask again)
        f.write(b'D %x %x\n' % (addr, n)); f.flush()
        line = f.readline().decode().strip()
        h = line[2:] if line.startswith('= ') else line      # (pad.py hands it on without the "= ")
        if len(h) >= 8 * n:
            return [int(h[8 * i:8 * i + 8], 16) for i in range(n)]
    raise RuntimeError('block read at %x: %r' % (addr, line[:80]))


def png(path, w, h, rgb):
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xFFFFFFFF)
    raw = b''.join(b'\0' + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
                           + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))


def main():
    out = sys.argv[1]
    w = int(sys.argv[2]) if len(sys.argv) > 2 else 640
    h = int(sys.argv[3]) if len(sys.argv) > 3 else 240
    f = socket.create_connection(('127.0.0.1', 5557), timeout=60).makefile('rwb')
    rgb = bytearray()
    words_per_row = (w + 1) // 2
    for y in range(h):
        ws = read_block(f, FB + 4 * (y * 320), words_per_row)
        for x in range(w):
            v = (ws[x >> 1] >> (16 * (x & 1))) & 0x7FFF
            r, g, b = v & 31, (v >> 5) & 31, (v >> 10) & 31
            rgb += bytes(((r << 3) | (r >> 2), (g << 3) | (g >> 2), (b << 3) | (b >> 2)))
    png(out, w, h, bytes(rgb))
    print(out, w, h)


if __name__ == '__main__':
    main()
