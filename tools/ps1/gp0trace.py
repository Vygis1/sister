"""gp0trace.py - the GPU input trace of a debug image (ps1_top DBG, over JTAG): the last 2048 things
that went into the GPU -- GP0 words from the CPU or the DMA, GP1 writes, and the DMA's linked-list
node headers. It stops when the engine starts an opcode 03-1E -- where the stream stopped making
sense.

    python tools/ps1/gp0trace.py arm          start it (it also starts cleared at power-up: armed by this)
    python tools/ps1/gp0trace.py [N]          show the last N words (default 80)
"""
import os
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
from jtag import Jtag  # noqa: E402

CTRL = 0x80000


def main():
    j = Jtag()
    if len(sys.argv) > 1 and sys.argv[1] == 'arm':
        j.write(CTRL + 0x1B0, 1)
        print('armed')
        j.close()
        return
    n_show = int(sys.argv[1]) if len(sys.argv) > 1 else 80
    st = j.read(CTRL + 0x1B0)
    n = st & 0xFFF
    frozen, on = st >> 31, (st >> 30) & 1
    words = j.read_block(CTRL + 0xC000, 2048)
    heads = [w & 3 for w in j.read_block(CTRL + 0xE000, 2048)]
    j.close()
    print('trace: %s, %s, %d entries' % ('armed' if on else 'not armed', 'STOPPED' if frozen else 'running', n))
    count = min(n, 2048)
    first = n - count
    lines = []
    for k in range(first, n):
        i = k % 2048
        tag = ('cpu ', 'dma ', 'GP1 ', 'NODE')[heads[i]]
        lines.append('%5d %s %08x' % (k, tag, words[i]))
    print('\n'.join(lines[-n_show:]))


if __name__ == '__main__':
    main()
