"""Capture a long run of frames from the web page and say what the picture does.

    python tools/ps1frames.py [count]        default 120

One frame tells you nothing about flicker. Flicker is the picture disagreeing
with itself over time, so this takes at least a hundred and twenty of them --
about four seconds at thirty a second -- and reports:

  fps              how fast distinct frames actually arrive
  churn            how much of the screen differs from the frame before
  period           whether the churn repeats on a cycle, which is what drawing
                   a screen in instalments looks like: the same few partial
                   states coming round again and again
  the steady map   which pixels never moved in the whole run
  a contact sheet  the frames themselves, shrunk and tiled, so the sequence can
                   be looked at rather than described

Writes build/console/sheet.png and build/console/steady.png.
"""
import os, sys, time, zlib, struct, urllib.request

S = "http://127.0.0.1:8080"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "console")


def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def png(path, w, h, rgb_rows):
    body = (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(rgb_rows), 6))
            + chunk(b"IEND", b""))
    open(path, "wb").write(body)


def rgb(p):
    r = (p & 31) << 3; g = ((p >> 5) & 31) << 3; b = ((p >> 10) & 31) << 3
    return (r | r >> 5, g | g >> 5, b | b >> 5)


def capture(n):
    # Every frame is kept, identical or not. Throwing the identical ones away
    # was wrong: two frames in a row being the same IS the thing being measured,
    # and on a steady picture it left nothing to measure at all.
    fs = []
    t0 = time.time()
    geom = [320, 240]
    last_id = None
    dups = 0
    while len(fs) < n:
        try:
            d = urllib.request.urlopen(S + "/api/vid/frame", timeout=8)
            body = d.read()
            # The geometry is whatever the board is SHOWING, not 320x240: a
            # 512-wide game is captured at 256, and the sheet used to index off
            # the end of the frame and crash halfway through the run.
            geom = [int(d.headers["X-Width"]), int(d.headers["X-Height"])]
            # Ask faster than the board sends and the same frame comes back
            # again: the whole run then reads as "nothing moved, 0% churn",
            # which is a measurement of this script, not of the picture. The
            # frame id says which one it is, so only keep new ones.
            # De-duplicate on CONTENT, not on the frame id: the board can send
            # the same capture again under a new id (it does whenever it
            # captures less often than the page asks), and counting those as
            # frames makes the churn read as near zero no matter what the
            # picture is doing.
            fid = body
            if fid == last_id:
                dups += 1
                if dups > 4000:
                    print("  the board stopped sending new frames"); break
                time.sleep(0.005)
                continue
            last_id = fid
            fs.append(body)
        except Exception as e:
            print("no picture:", e); sys.exit(1)
    return fs, time.time() - t0, geom


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 120
    fs, dt, (W, H) = capture(n)
    fs = [f for f in fs if len(f) >= W * H * 2]
    if not fs:
        print("  no frame came back at the size the board reports (%dx%d)" % (W, H)); sys.exit(1)
    print("  the board is showing %dx%d" % (W, H))
    px = W * H
    same = sum(1 for i in range(len(fs) - 1) if fs[i] == fs[i + 1])
    print("  %d frames in %.2f s  -> %.1f a second   (%d of %d identical to the one before)"
          % (len(fs), dt, len(fs) / dt, same, len(fs) - 1))

    # --- how much moves between one frame and the next ----------------------
    ds = []
    for i in range(len(fs) - 1):
        a, b = fs[i], fs[i + 1]
        d = sum(1 for k in range(0, len(a), 2) if a[k:k + 2] != b[k:k + 2])
        ds.append(100.0 * d / px)
    if ds:
        print("  churn between frames: min %.1f%%  max %.1f%%  average %.1f%%"
              % (min(ds), max(ds), sum(ds) / len(ds)))
    else:
        print("  churn between frames: nothing to compare")
        return

    # --- does the churn repeat? an instalment pattern has a period ----------
    best, bestlag = 0.0, 0
    m = sum(ds) / len(ds)
    var = sum((x - m) ** 2 for x in ds) or 1e-9
    for lag in range(2, min(40, len(ds) // 3)):
        c = sum((ds[i] - m) * (ds[i + lag] - m) for i in range(len(ds) - lag))
        c /= var
        if c > best:
            best, bestlag = c, lag
    print("  strongest repeat: every %d frames (strength %.2f)" % (bestlag, best))
    if best > 0.45:
        print("  -> the same partial states keep coming round: drawn in instalments")
    elif max(ds) - min(ds) < 4:
        print("  -> steady")

    # --- which pixels never moved at all -----------------------------------
    steady = bytearray()
    nmoved = 0
    for y in range(H):
        steady.append(0)
        for x in range(W):
            k = (y * W + x) * 2
            v = fs[0][k:k + 2]
            moved = any(f[k:k + 2] != v for f in fs)
            if moved:
                nmoved += 1
                steady += bytes((255, 40, 40))
            else:
                r, g, b = rgb(fs[0][k] | (fs[0][k + 1] << 8))
                steady += bytes((r // 3, g // 3, b // 3))
    png(OUT + "/steady.png", W, H, steady)
    print("  %d of %d pixels (%.0f%%) moved at least once in the whole run"
          % (nmoved, px, 100.0 * nmoved / px))

    # --- a contact sheet: 24 frames spread across the run, quarter size -----
    COLS, ROWS = 6, 4
    pick = [fs[i * (len(fs) - 1) // (COLS * ROWS - 1)] for i in range(COLS * ROWS)]
    tw, th = W // 4, H // 4
    SW, SH = COLS * tw, ROWS * th
    sheet = bytearray()
    for sy in range(SH):
        sheet.append(0)
        ty, ry = sy // th, sy % th
        for sx in range(SW):
            tx, rx = sx // tw, sx % tw
            f = pick[ty * COLS + tx]
            k = ((ry * 4) * W + rx * 4) * 2
            sheet += bytes(rgb(f[k] | (f[k + 1] << 8)))
    png(OUT + "/sheet.png", SW, SH, sheet)
    print("  wrote sheet.png (24 frames across the run) and steady.png")


if __name__ == "__main__":
    main()
