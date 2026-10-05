"""Measure the PlayStation core the way the goal is stated.

    python tools/ps1/ps1bench.py [seconds]

Waits until Crash is actually showing a moving 3D scene -- not the loading
screen, not the title card -- then reports:

  * the frame rate as MEDIAN and 1% LOW, taken from the console's own display
    flips, because that is what the goal is about;
  * how many frames contain an anomalously large red shape in the corner where
    the fruit counter lives, which is the "popping" artifact made countable.

No best-case numbers. If it did not run, it says so.
"""
import os, sys, time, urllib.request
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "pc"))
import fpgalink as fl

N = 0x0008_0000
A40 = {0x5c4, 0x5c8, 0x5cc, 0x5d0, 0x5d4, 0x5d8, 0x5dc, 0xa0, 0xa4, 0xa8, 0xac,
       0xbfc0d8e0, 0xbfc0d8e4, 0xbfc0d8e8}


def frame():
    d = urllib.request.urlopen("http://127.0.0.1:8080/api/vid/frame", timeout=20)
    return d.read(), int(d.headers["X-Width"]), int(d.headers["X-Height"])


def scene_is_up(f, w):
    colours = len(set(f[k] | (f[k + 1] << 8) for k in range(0, len(f), 16)))
    return colours > 300


def corner_red(f, w):
    n = 0
    for y in range(4, 40):
        for x in range(0, 70):
            p = f[2 * (y * w + x)] | (f[2 * (y * w + x) + 1] << 8)
            if (p & 31) > 18 and ((p >> 5) & 31) < 16 and ((p >> 10) & 31) < 12:
                n += 1
    return n


def main():
    secs = int(sys.argv[1]) if len(sys.argv) > 1 else 60
    l = fl.Link(fl.DEFAULT_HOST, 5005, timeout=1.0, retries=6)

    t0 = time.time()
    while time.time() - t0 < 240:
        f, w, h = frame()
        if scene_is_up(f, w):
            break
        time.sleep(2)
    else:
        print("no 3D scene came up within four minutes"); return 1

    gaps = []
    reds = []
    prev = None
    last = time.time()
    t0 = time.time()
    next_grab = t0
    while time.time() - t0 < secs:
        v = l.read(N + 0x6C) & 0x3FF
        now = time.time()
        if prev is not None and v != prev:
            gaps.append(now - last); last = now
        prev = v
        if now >= next_grab:
            f, w, h = frame()
            reds.append(corner_red(f, w))
            next_grab = now + 0.5
        pcs = [l.read(N + 0x14) for _ in range(4)]
        if all(p in A40 for p in pcs):
            print("THE CONSOLE FROZE after %.0f s (BIOS exception loop)" % (time.time() - t0))
            break

    if len(gaps) < 20:
        print("only %d display flips in %.0f s -- the game is not drawing" % (len(gaps), secs))
        return 1
    gaps.sort()
    n = len(gaps)
    med = gaps[n // 2]
    low = gaps[int(n * 0.99) - 1]
    print("frames: %d in %.0f s" % (n, secs))
    print("  median %.1f ms -> %.1f fps" % (med * 1000, 1 / med))
    print("  1%% low %.1f ms -> %.1f fps" % (low * 1000, 1 / low))
    if reds:
        reds_sorted = sorted(reds)
        mid = reds_sorted[len(reds) // 2]
        bad = sum(1 for r in reds if r > mid * 3 + 50)
        print("  corner shape: median %d px, %d of %d frames far above it" % (mid, bad, len(reds)))
    print("VERDICT: %s" % ("meets 30 fps" if 1 / med >= 29.5 and 1 / low >= 24
                           else "does NOT meet the bar (want median 30, 1%% low 25)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
