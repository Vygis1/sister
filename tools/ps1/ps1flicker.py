"""Watch a second of the picture the web page is serving and say whether it is steady.

    python tools/ps1/ps1flicker.py [seconds]

Looking at one frame cannot tell you anything about flicker. Flicker is the
picture being DIFFERENT from one frame to the next -- the drawing engine not
finishing inside a frame, so the scanout catches a half-drawn screen and a
different half each time. So this takes every frame it can for a second and
reports how much the lit-pixel count moves between them.

  spread small   the same picture every frame: steady
  spread large   the frames disagree: that is the flicker, and the size of the
                 swing says how much of the screen is arriving late
"""
import sys, time, urllib.request

SERVER = "http://127.0.0.1:8080"


def frame():
    r = urllib.request.urlopen(SERVER + "/api/vid/frame", timeout=8)
    b = r.read()
    w = int(r.headers.get("X-Width", 0) or 0)
    h = int(r.headers.get("X-Height", 0) or 0)
    lit = sum(1 for k in range(0, len(b), 2) if b[k:k + 2] != b"\x00\x00")
    return w, h, lit, len(b) // 2, b


def main():
    secs = float(sys.argv[1]) if len(sys.argv) > 1 else 1.0
    t0 = time.time()
    seen = []
    last = None
    while time.time() - t0 < secs:
        try:
            w, h, lit, total, b = frame()
        except Exception as e:
            print("no picture:", e)
            return
        if b != last:                 # only count frames that actually changed
            seen.append((lit, total, w, h))
            last = b
    dt = time.time() - t0
    if not seen:
        print("the picture never changed in %.1f s" % dt)
        return
    lits = [s[0] for s in seen]
    total, w, h = seen[0][1], seen[0][2], seen[0][3]
    lo, hi = min(lits), max(lits)
    avg = sum(lits) / float(len(lits))
    print("  %d distinct frames in %.2f s  (%.1f a second)   %dx%d" % (len(seen), dt, len(seen) / dt, w, h))
    print("  lit pixels   low %d   high %d   average %.0f   of %d" % (lo, hi, avg, total))
    swing = 100.0 * (hi - lo) / (avg or 1)
    print("  frame-to-frame swing %.1f%% of the picture" % swing)
    if swing < 5:
        print("  STEADY - the frames agree, the engine is finishing inside a frame")
    elif swing < 25:
        print("  SOME MOVEMENT - either real animation, or a little arriving late")
    else:
        print("  FLICKERING - the frames disagree badly; the picture is arriving in instalments")
    print("  the counts, in order:")
    print("   ", " ".join(str(x) for x in lits[:40]))


if __name__ == "__main__":
    main()
