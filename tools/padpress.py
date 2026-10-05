"""padpress.py - press buttons on the board's joypad 1 from the PC, held long enough to
survive pc/pad.py's half-second refresh: each press is rewritten every 20 ms for
250 ms, then released. The value is in the running machine's own bit order.

    from padpress import press;  press(0x40)
"""
import sys, time, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import n64dbg

JOY1 = 0x00080008


def press(v, hold=0.25, gap=0.5):
    t0 = time.time()
    while time.time() - t0 < hold:
        n64dbg.reg(JOY1, v)
        time.sleep(0.02)
    n64dbg.reg(JOY1, 0)
    time.sleep(gap)


def osd_open():
    return n64dbg.reg(0x00070004) & 1
