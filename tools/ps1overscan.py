"""Does the picture still flash between two states, and did the fix cost anything?

    python tools/ps1overscan.py

The rows a game never draws keep whatever VRAM held before them, and the two
buffers of a double-buffered game hold different leftovers -- so those rows
flash at the flip rate. The capture blanks them (ps1_gpu, `sc_crop`), and
ctrl 0xF0 bit 26 turns that off again, so the same run can measure both.

Reports, for each setting:
  alternating pixels   pixels whose value keeps returning to what it was two
                       frames ago while differing from the frame between: a
                       picture flipping between two states
  where they are       by row, so "outside the drawing area" is visible as such
  lit pixels           so blanking something that should have been drawn shows
                       up as the picture losing content
"""
import sys, time, urllib.request, numpy as np
sys.path.insert(0, r"C:/fpga/pc")
import fpgalink as fl

N = 0x0008_0000
S = "http://127.0.0.1:8080"
BOARD = "192.168.178.50"


def grab(n, link=None, ctl=None):
    fs, last = [], None
    while len(fs) < n:
        # the server re-arms the stream whenever a frame is asked for, and that
        # rewrites ctrl 0xF0 -- so the switch has to be put back as we go, or
        # half of an A/B run is measured with the other setting
        if link is not None and (len(fs) & 7) == 0:
            link.write(N + 0xF0, ctl)
        d = urllib.request.urlopen(S + "/api/vid/frame", timeout=8)
        b = d.read()
        W, H = int(d.headers["X-Width"]), int(d.headers["X-Height"])
        if b == last:
            time.sleep(0.004); continue
        last = b
        fs.append(np.frombuffer(b[:W * H * 2], dtype='<u2').reshape(H, W).astype(np.int32))
    return np.stack(fs)


def report(label, link, ctl, n=200):
    A = grab(n, link, ctl)
    e1 = (A[2:] == A[1:-1]); e2 = (A[2:] == A[:-2])
    alt = (e2 & ~e1).mean(0)                 # 0.5 is a perfect two-state flip
    m = alt > 0.35
    lit = ((A & 0x7FFF) != 0).mean(0)
    print(f"  {label}")
    print(f"    alternating pixels: {m.sum()}   (0 is a picture that does not flash)")
    if m.any():
        rows = np.nonzero(m.any(1))[0]
        print(f"    on rows {rows.min()}..{rows.max()}  ({len(rows)} rows)")
    print(f"    lit pixels a frame: {lit.sum():.0f}")
    return m.sum(), lit.sum()


def main():
    link = fl.Link(BOARD)
    ctl = link.read(N + 0xF0)
    try:
        on, off = ctl & ~(1 << 26), ctl | (1 << 26)
        link.write(N + 0xF0, on); time.sleep(0.5)
        a_n, a_lit = report("blanking the rows outside the drawing area", link, on)
        link.write(N + 0xF0, off); time.sleep(0.5)
        b_n, b_lit = report("sending them as they are (ctrl 0xF0 bit 26)", link, off)
    finally:
        link.write(N + 0xF0, ctl & ~(1 << 26))
    print()
    print(f"  flashing pixels {b_n} -> {a_n}")
    print(f"  picture content {b_lit:.0f} -> {a_lit:.0f} lit pixels"
          f"  ({100.0 * (a_lit - b_lit) / max(b_lit, 1):+.1f}%)")
    if a_lit < 0.9 * b_lit:
        print("  WARNING: the picture lost content -- the blanking is taking rows the game drew")


if __name__ == "__main__":
    main()
