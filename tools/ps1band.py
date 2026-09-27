"""What is the flat band in a delivered frame made of?

    python tools/ps1band.py [frames]        default 120

The page shows bands of one flat colour where part of the picture should be,
and the boundary moves from frame to frame. Two things could do that: the
capture reading video memory wrong, or the frame the host assembles being two
different pictures stuck together. tb_ps1_scan settles the first -- the capture
reads out what video memory holds, under every latency, with the engine
competing for the cache, and across buffer flips. So this asks the second
question of the frames themselves, with no board access at all:

  * how many delivered frames contain a run of rows that is one flat colour,
    where it starts and how long it is;
  * whether the rows BELOW the boundary are the TOP of another picture -- which
    is what a frame assembled from two captures would look like;
  * whether they are instead the same rows from an earlier frame.

Frames are taken by the board's own frame id, never by content: skipping frames
whose content repeats cannot tell a still picture from a stalled capture.
"""
import sys, time, urllib.request

S = "http://127.0.0.1:8080"


def grab(n, secs=90):
    fs, lastid, t0 = [], None, time.time()
    w = h = 0
    while len(fs) < n and time.time() - t0 < secs:
        try:
            d = urllib.request.urlopen(S + "/api/vid/frame", timeout=20)
            b = d.read()
        except Exception:
            continue
        w, h = int(d.headers["X-Width"]), int(d.headers["X-Height"])
        fid = d.headers.get("X-Frame")
        if len(b) < w * h * 2 or fid == lastid:
            time.sleep(0.005)
            continue
        lastid = fid
        fs.append((fid, b[:w * h * 2]))
    return fs, w, h


def rows(buf, w, h):
    return [buf[y * w * 2:(y + 1) * w * 2] for y in range(h)]


def flat_runs(rs, minlen=16):
    """Runs of consecutive rows that are each a single repeated pixel."""
    out = []
    y = 0
    while y < len(rs):
        r = rs[y]
        v = r[0:2]
        if r != v * (len(r) // 2):
            y += 1
            continue
        y0 = y
        while y < len(rs) and rs[y] == v * (len(rs[y]) // 2):
            y += 1
        if y - y0 >= minlen:
            out.append((y0, y - y0, v[0] | (v[1] << 8)))
    return out


def first_diff_row(a, b):
    """The topmost row where two frames differ, and the bottom-most."""
    top = None
    bot = None
    for y in range(len(a)):
        if a[y] != b[y]:
            if top is None:
                top = y
            bot = y
    return top, bot


def match_rows(x, y):
    """How many of the two row lists are identical, pairwise."""
    return sum(1 for a, b in zip(x, y) if a == b)


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 120
    fs, w, h = grab(n)
    if len(fs) < 4:
        print("only %d frames came back" % len(fs))
        return
    print("%d frames of %dx%d" % (len(fs), w, h))
    allrows = [rows(b, w, h) for _, b in fs]

    banded = 0
    splice_own_top = 0
    splice_neighbour_top = 0
    same_rows_prev = 0
    reported = 0
    for i, rs in enumerate(allrows):
        runs = flat_runs(rs)
        if not runs:
            continue
        banded += 1
        y0, ln, val = max(runs, key=lambda r: r[1])
        # Is the flat band the TOP of a picture, pasted in at row y0? Then the
        # rows from y0 down are rows 0.. of some capture.
        k = min(ln + 40, h - y0)
        own = match_rows(rs[y0:y0 + k], rs[0:k])
        nb = 0
        for j in (i - 1, i + 1):
            if 0 <= j < len(allrows):
                nb = max(nb, match_rows(rs[y0:y0 + k], allrows[j][0:k]))
        prev = 0
        if i > 0:
            prev = match_rows(rs[y0:y0 + k], allrows[i - 1][y0:y0 + k])
        if own > k * 0.8:
            splice_own_top += 1
        if nb > k * 0.8:
            splice_neighbour_top += 1
        if prev > k * 0.8:
            same_rows_prev += 1
        if reported < 6:
            reported += 1
            print("  frame %s: flat %04x for %d rows from row %d of %d" % (fs[i][0], val, ln, y0, h))
            print("      of the %d rows from there: %d match this frame's own top,"
                  " %d match a neighbour's top, %d match the same rows one frame back"
                  % (k, own, nb, prev))

    print()
    print("BANDS: %d of %d frames carry a flat run of 16 rows or more" % (banded, len(fs)))
    if banded:
        print("  of those, %d have the band's rows matching the top of a picture (this frame)" % splice_own_top)
        print("            %d matching the top of a neighbouring frame" % splice_neighbour_top)
        print("            %d unchanged from the same rows one frame earlier" % same_rows_prev)

    # A boundary does not have to be flat. Look for one directly: the row above
    # which a frame equals its neighbour and below which it does not, or the
    # reverse -- a frame made of two captures has exactly one such row.
    print()
    seams = 0
    for i in range(1, len(allrows)):
        a, b = allrows[i - 1], allrows[i]
        same = [a[y] == b[y] for y in range(h)]
        changes = sum(1 for y in range(1, h) if same[y] != same[y - 1])
        if changes == 1 and 8 < sum(same) < h - 8:
            seams += 1
    print("SEAMS: %d of %d consecutive pairs split cleanly at one row"
          " (the top identical, the bottom not, or the other way round)" % (seams, len(allrows) - 1))


if __name__ == "__main__":
    main()
