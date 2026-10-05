"""Read the N64's RDRAM on the board, through the console's one-line DDR3 window
(ctrl 0x7C: write a line index, wait for bit 31; 0x80..0x8C: its four words).

    python tools/n64/n64ram.py ADDRESS [LENGTH]      (an N64 address: 0x8033BAC6 or physical)
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from n64dbg import reg   # noqa: E402

NES = 0x0008_0000


def read(addr, n):
    addr &= 0x00FFFFFF
    out = bytearray()
    for line in range(addr >> 4, (addr + n + 15) >> 4):
        reg(NES + 0x7C, line)
        for _ in range(200):
            if reg(NES + 0x7C) >> 31:
                break
        out += b''.join(struct.pack('<I', reg(NES + 0x80 + 4 * k)) for k in range(4))
    o = addr & 15
    return bytes(out[o:o + n])


if __name__ == '__main__':
    a = int(sys.argv[1], 0)
    n = int(sys.argv[2], 0) if len(sys.argv) > 2 else 16
    print(read(a, n).hex())
