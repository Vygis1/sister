"""How many delivered frames are two pictures stuck together?

    python tools/ps1/ps1splice.py [frames]        default 150

The picture the page shows tears, and the way it tears is a clean horizontal
line: above it one moment of the game, below it another. That reads on screen as
the whole scene snapping between two camera positions -- the "boxes and
characters swapping which side is nearer".

Measured here as: for each pair of consecutive delivered frames, is there a row
R such that the rows above R are nearly identical and the rows below R nearly
all differ (or the other way round)? A frame that is one picture changes a
little everywhere as things move. A frame that is two pictures changes in a
block, with a sharp edge.

Frames are taken by the board's own frame id, never by content: skipping frames
whose content repeats cannot tell a still picture from a stalled capture.

Print the numbers before and after a change. A single run means nothing.
"""
import sys, time, urllib.request, collections

S = "http://127.0.0.1:8080"


def grab(n, secs=120):
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
            time.sleep(0.004)
            continue
        lastid = fid
        fs.append((int(fid), b[:w * h * 2]))
    return fs, w, h


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 150
    t0 = time.time()
    fs, w, h = grab(n)
    wall = time.time() - t0
    if len(fs) < 8:
        print("only %d frames came back -- nothing to measure" % len(fs))
        return
    print("%d frames of %dx%d in %.1f s (%.1f a second)" % (len(fs), w, h, wall, len(fs) / wall))

    ids = [f for f, _ in fs]
    steps = collections.Counter(b - a for a, b in zip(ids, ids[1:]))
    print("frame id steps: %s" % ", ".join("+%d x%d" % (k, v) for k, v in sorted(steps.items())))

    # A static sky makes the top of every frame identical to the top of the one
    # before, so "the frames split cleanly at one row" flags a perfectly healthy
    # picture. It measured the scene, not a fault, and it read 90% on a build
    # whose frames looked right. The sound test is about WHICH MOMENT each part
    # of a frame belongs to: if the bottom of frame N is identical to the bottom
    # of frame N+1 while its top is not, then frame N's bottom was captured after
    # its top -- two moments in one delivered frame, which is the tear.
    rows_of = lambda b: [b[y * w * 2:(y + 1) * w * 2] for y in range(h)]
    rs = [rows_of(b) for _, b in fs]
    moving = [y for y in range(h)
              if sum(1 for a, b in zip(rs, rs[1:]) if a[y] != b[y]) > 0.3 * (len(rs) - 1)]
    print("rows that actually move: %d of %d%s" % (len(moving), h,
          ("  (%d..%d)" % (moving[0], moving[-1])) if moving else ""))
    if len(moving) < 16:
        print("almost nothing is moving -- drive the game into a level before measuring")
        return

    spliced = 0
    seam_at = collections.Counter()
    for i in range(1, len(rs) - 1):
        prev, cur, nxt = rs[i - 1], rs[i], rs[i + 1]
        # walking down the moving rows: does this frame stop agreeing with the
        # one before and start agreeing with the one after, at one place?
        belongs_next = [ (cur[y] == nxt[y]) and (cur[y] != prev[y]) for y in moving ]
        belongs_prev = [ (cur[y] == prev[y]) and (cur[y] != nxt[y]) for y in moving ]
        if sum(belongs_next) >= 4 and sum(belongs_prev) >= 4:
            # both halves present: find where it changes over
            first_next = next((k for k, v in enumerate(belongs_next) if v), None)
            if first_next is not None and first_next > 0:
                spliced += 1
                seam_at[moving[first_next]] += 1

    pairs = len(rs) - 2
    print()
    print("frames whose BOTTOM belongs to the next frame and TOP to the previous")
    print("  (two moments in one delivered frame)        : %d of %d  (%.0f%%)"
          % (spliced, pairs, 100.0 * spliced / max(1, pairs)))
    if seam_at:
        print("  where the changeover happens: %s"
              % ", ".join("row %d x%d" % (k, v) for k, v in seam_at.most_common(8)))

    churn = []
    for a, b in zip(rs, rs[1:]):
        churn.append(sum(1 for x, y in zip(a, b) if x != y) / float(h))
    print("rows that changed, frame to frame: mean %.0f%% of the picture"
          % (100.0 * sum(churn) / len(churn)))


if __name__ == "__main__":
    main()
