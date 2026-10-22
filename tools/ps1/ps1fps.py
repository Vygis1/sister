"""ps1fps.py - the PlayStation game's frame rate on the board, from its own display flips: how
often the displayed buffer (console 0x6C, dbg_disp: y [25:17], x [9:0]) changes, read through tools/pad.py's
tool port -- no network. Reported per second, then the median and the slowest second.

    python tools/ps1/ps1fps.py [SECONDS]
"""
import socket
import statistics
import sys
import time

f = socket.create_connection(('127.0.0.1', 5557), timeout=5).makefile('rwb')


def rd(a):
    f.write(b'R %08x\n' % a); f.flush()
    return int(f.readline().split()[-1], 16)


DISP = (0x1FF << 17) | 0x3FF     # (the old 0x7FFFF missed every flip between y 0 and y 240)
secs = int(sys.argv[1]) if len(sys.argv) > 1 else 20
last = rd(0x0008006C) & DISP
per = [0] * secs
t0 = time.time()
while True:
    t = time.time() - t0
    if t >= secs:
        break
    v = rd(0x0008006C) & DISP
    if v != last:
        per[int(t)] += 1
        last = v
print('flips a second:', ' '.join(str(p) for p in per))
print('median %.0f fps, slowest second %d fps' % (statistics.median(per), min(per)))
