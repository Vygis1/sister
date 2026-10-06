"""rtring.py - the N64 CPU's last 512 retired instructions, as the board froze them at the first
TLB / address / bus fault (n64_top's retire ring, DBG builds), through pc/pad.py's tool port.

    python tools/n64/rtring.py [OUT]      -> OUT (default build/rtring.txt), oldest first, in
                                             tools/n64/n64sim.py's trace format

dbg_sel (console 0x170): [28] the ring, [16:8] the entry, [27:26] the word
(0 pc, 1 {frozen, code [12:8], we [6], rd [4:0]}, 2 value hi, 3 value lo); 0x174 the answer.
"""
import os
import socket
import sys

NES = 0x00080000
f = socket.create_connection(('127.0.0.1', 5557), timeout=10).makefile('rwb')


def q(c):
    f.write((c + '\n').encode()); f.flush()
    return f.readline().decode().strip()


def word(k, w):
    q('W %08x %x' % (NES + 0x170, (1 << 28) | (w << 26) | (k << 8)))
    return int(q('R %08x' % (NES + 0x174)).split()[-1], 16)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..', '..', 'build', 'rtring.txt')
    st = word(0, 1)
    if not st >> 31:
        print('the ring is not frozen: no fault yet')
        return
    print('frozen at exception code %d' % ((st >> 8) & 31))
    lines = []
    for k in range(512):
        pc, m = word(k, 0), word(k, 1)
        if m >> 6 & 1:
            v = word(k, 2) << 32 | word(k, 3)
            lines.append('%08x %02d %016x' % (pc, m & 31, v))
        else:
            lines.append('%08x' % pc)
    lines.append('X %02x' % ((st >> 8) & 31))
    open(out, 'w').write('\n'.join(lines) + '\n')
    print('\n'.join(lines[-40:]))
    print(out)


if __name__ == '__main__':
    main()
