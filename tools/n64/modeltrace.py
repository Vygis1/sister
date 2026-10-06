"""modeltrace.py - what the model's CPU did around a PC: SM64 (or any ROM) run in the model with
the RDP drawing (as tools/n64/n64rdptests.py's game mode), the last 512 retired instructions kept
from frame FROM on, written out AFTER instructions past the first time PC is reached -- for
holding against the board's retire ring (tools/n64/rtring.py).

    python tools/n64/modeltrace.py ROM PC [FROM_FRAME] [AFTER] [OUT]
"""
import collections
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import n64model       # noqa: E402
import n64rdptests    # noqa: E402


def main():
    rom = open(sys.argv[1], 'rb').read()
    target = int(sys.argv[2], 16)
    frm = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    after = int(sys.argv[4]) if len(sys.argv) > 4 else 64
    out = sys.argv[5] if len(sys.argv) > 5 else os.path.join(HERE, '..', '..', 'build', 'modeltrace.txt')
    m = n64model.N64(rom)
    n64rdptests.ensure_rdp(m)
    m.fast_boot()
    c = m.cpu
    t0 = time.time()
    while m.vi_frames < frm:
        for _ in range(4096):
            c.step()
    print('frame %d after %.0f s; tracing' % (m.vi_frames, time.time() - t0), flush=True)
    ring = collections.deque(maxlen=512)
    left = None
    while left is None or left > 0:
        pc = c.pc & 0xFFFFFFFF
        before = list(c.r)
        c.step()
        if c.last_exc is not None:
            ring.append('X %02x' % c.last_exc)
        else:
            wrote = [i for i in range(1, 32) if c.r[i] != before[i]]
            ring.extend(['%08x %02d %016x' % (pc, i, c.r[i] & 0xFFFFFFFFFFFFFFFF) for i in wrote] or ['%08x' % pc])
        if left is None and pc == target:
            left = after
            print('reached %08x at frame %d' % (target, m.vi_frames), flush=True)
        elif left is not None:
            left -= 1
    open(out, 'w').write('\n'.join(ring) + '\n')
    print(out)


if __name__ == '__main__':
    main()
