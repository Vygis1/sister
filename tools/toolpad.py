"""toolpad.py - press buttons on the board from the PC's tools, through pc/pad.py's tool port
(the pad's own bits: 0 cross, 1 circle, 2 square, 3 triangle, 4 select, 5 start, 6-9 up/down/
left/right, 10 L1, 11 R1, 12 L2, 13 R2, 14 PS).

    from toolpad import press;  press(1 << 7)          # down
"""
import socket
import time

CROSS, CIRCLE, SQUARE, TRIANGLE, SELECT, START = 1, 2, 4, 8, 16, 32
UP, DOWN, LEFT, RIGHT = 64, 128, 256, 512
_f = None


def _line(s):
    global _f
    if _f is None:
        _f = socket.create_connection(('127.0.0.1', 5557), timeout=5).makefile('rwb')
    _f.write(s.encode() + b'\n'); _f.flush(); _f.readline()


def press(bits, hold=0.1, gap=0.4, axes=(0, 0, 0, 0)):
    """bits down for `hold` seconds, then released, then `gap` seconds"""
    t0 = time.time()
    while time.time() - t0 < hold:
        _line('P %x %d %d %d %d' % (bits, *axes)); time.sleep(0.03)
    _line('P 0 0 0 0 0')
    time.sleep(gap)
