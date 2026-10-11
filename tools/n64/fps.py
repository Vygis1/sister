"""fps.py - the N64 game's frame rate on the board: how often VI_ORIGIN (console 0x154) changes,
read through pc/pad.py's tool port.     python tools/n64/fps.py [SECONDS]"""
import socket, sys, time
f = socket.create_connection(('127.0.0.1', 5557), timeout=5).makefile('rwb')
def rd(a):
    f.write(b'R %08x\n' % a); f.flush(); return int(f.readline().split()[-1], 16)
secs = float(sys.argv[1]) if len(sys.argv) > 1 else 10
last, n, t0, per = rd(0x00080154), 0, time.time(), []
while time.time() - t0 < secs:
    v = rd(0x00080154)
    if v != last: n += 1; last = v
print('%.1f frames/s over %.0f s (VI_ORIGIN changes)' % (n / secs, secs))
