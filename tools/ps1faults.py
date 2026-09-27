"""Count the visible faults in a run of frames, so a fix can be judged.

    python tools/ps1faults.py [frames]      default 150

Two things a person watching points at, made countable:

  stray polygons   a runaway vertex drags a polygon across the screen as a long
                   thin streak, and the ones that show are usually magenta or
                   white because they are textured from somewhere they should
                   not be. Counted as pixels whose red and blue are high and
                   green is low -- a colour almost nothing in Crash's world is.
  alternation      the picture going back and forth between two states instead
                   of forward, which reads as characters turning left and right.
                   Measured as: is a frame more like the one TWO ahead than the
                   one next to it?

Neither number means anything on its own. Both are for before-and-after.
"""
import sys, time, urllib.request, hashlib

S = "http://127.0.0.1:8080"


def grab(n):
    out, seen, t0 = [], None, time.time()
    while len(out) < n and time.time() - t0 < 120:
        d = urllib.request.urlopen(S + "/api/vid/frame", timeout=10)
        body = d.read()
        h = hashlib.md5(body).hexdigest()
        if h == seen:
            time.sleep(0.004); continue
        seen = h
        out.append((body, int(d.headers["X-Width"]), int(d.headers["X-Height"])))
    return out


def magenta(body, w, h):
    """pixels that are strongly red+blue with little green"""
    n = 0
    for y in range(12, h):                       # skip the overscan band
        for x in range(0, w, 2):
            p = body[2 * (y * w + x)] | (body[2 * (y * w + x) + 1] << 8)
            r, g, b = p & 31, (p >> 5) & 31, (p >> 10) & 31
            if r >= 20 and b >= 20 and g <= 8:
                n += 1
    return n


def diff(a, b):
    n = 0
    for k in range(0, len(a), 32):
        if a[k] != b[k] or a[k + 1] != b[k + 1]:
            n += 1
    return 100.0 * n / (len(a) // 32)


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 150
    fs = grab(n)
    if len(fs) < 8:
        print("  only %d frames came back" % len(fs)); return 1
    w, h = fs[0][1], fs[0][2]
    m = [magenta(b, w, h) for b, _, _ in fs]
    bad = sum(1 for x in m if x > 40)
    print("  %d frames of %dx%d" % (len(fs), w, h))
    print("  stray-polygon pixels: median %d, worst %d, %d of %d frames over 40 (%.0f%%)"
          % (sorted(m)[len(m) // 2], max(m), bad, len(fs), 100.0 * bad / len(fs)))
    d1 = [diff(fs[i][0], fs[i + 1][0]) for i in range(len(fs) - 1)]
    d2 = [diff(fs[i][0], fs[i + 2][0]) for i in range(len(fs) - 2)]
    a1, a2 = sum(d1) / len(d1), sum(d2) / len(d2)
    print("  difference to the next frame %.1f%%, to the one after %.1f%%  -> %s"
          % (a1, a2, "ALTERNATING between two states" if a2 < a1 else "moving forward"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
