"""Run the game, prove the scene is alive, and catch the moment it stops.

    python tools/ps1/ps1watch.py [seconds] [--no-reboot]

A frame rate measured off display flips is a lie if the game has frozen: a
frozen game still flips its buffers at 30 a second, drawing the same list. So
this samples the drawing engine's own pixel and primitive counters every
second. Identical counts, to the pixel, mean the game's state is not advancing
-- and the moment that starts, it dumps everything that could say why:

  where the processor is (a histogram, not one sample)
  SR / CAUSE / EPC, the drive's command trace, the DMA and interrupt counters

and then keeps watching, so a stall that ends is reported as a stall that
ended rather than as a freeze.
"""
import os, sys, time, collections
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "pc"))
import fpgalink as fl

OUTDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "build", "console")

N = 0x0008_0000
A40 = {0x5c4,0x5c8,0x5cc,0x5d0,0x5d4,0x5d8,0x5dc,0xa0,0xa4,0xa8,0xac,
       0xbfc0d8e0,0xbfc0d8e4,0xbfc0d8e8}
NAMES = {0x01:"GetStat",0x02:"Setloc",0x06:"ReadN",0x08:"Stop",0x09:"Pause",
         0x0a:"Init",0x0e:"Setmode",0x11:"GetlocP",0x15:"SeekL",0x16:"SeekP",
         0x1a:"GetID",0x1b:"ReadS"}


def bcd(x):
    return (x >> 4) * 10 + (x & 15)


class Board:
    # A measurement that runs for ten minutes shares the network with the frame
    # streamer, and a burst of dropped UDP outlives the link's own retries now
    # and then. Dying on that loses the whole run and -- worse -- looks exactly
    # like the board having crashed. So every access retries here too, and the
    # drops are counted and reported rather than hidden.
    def __init__(self):
        self.l = fl.Link(fl.DEFAULT_HOST, 5005, timeout=1.0, retries=4)
        self.drops = 0

    def _try(self, fn, *a):
        for attempt in range(12):
            try:
                return fn(*a)
            except (fl.LinkTimeout, OSError):
                self.drops += 1
                time.sleep(0.25)
        raise fl.LinkTimeout("the board stopped answering for three seconds")

    def rd(self, a):
        return self._try(self.l.read, N + a)

    def wr(self, a, v):
        return self._try(self.l.write, N + a, v)

    def c(self, i):
        self.wr(0xEC, i); return self.rd(0xEC)

    def peek(self, i):
        self.wr(0x9C, i); return self.rd(0x9C)

    def reboot(self):
        ctrl = self.rd(4)
        self.wr(4, ctrl & ~1); time.sleep(0.05); self.wr(4, ctrl | 1)

    def trace(self, n=16):
        wp = self.rd(0x110) & 0x3F
        out = []
        for i in range(64 - n, 64):
            k = (wp + i) & 0x3F
            self.wr(0x110, k); e = self.rd(0x114)
            c = e >> 24; p = [(e >> 16) & 255, (e >> 8) & 255, e & 255]
            s = "%-8s %02x %02x %02x" % (NAMES.get(c, "%02x" % c), p[0], p[1], p[2])
            if c == 0x02: s += "  LBA %d" % (bcd(p[0]) * 4500 + bcd(p[1]) * 75 + bcd(p[2]) - 150)
            if c == 0x5b: s = "sector taken LBA %d" % (e & 0xFFFFFF)
            if c == 0x5e: s = "SECTOR REFUSED LBA %d" % (e & 0xFFFFFF)
            if c == 0x11: s = "INT1 LBA %d" % (e & 0xFFFFFF)
            if c == 0xd3: s = "DMA3 start"
            if c == 0xd4: s = "DMA3 done %d words" % (e & 0xFFFF)
            if c == 0xb0: s = "HCHPCTL=%02x" % p[0]
            out.append(s)
        return out

    def why(self):
        h = collections.Counter()
        for _ in range(240):
            h[self.rd(0x14)] += 1
        print("    pc: " + "  ".join("%08x x%d" % (p, n) for p, n in h.most_common(6)))
        print("    SR %08x  CAUSE %08x (excode %d)  EPC %08x  ra %08x"
              % (self.peek(0x20), self.peek(0x21), (self.peek(0x21) >> 2) & 31,
                 self.peek(0x22), self.peek(31)))
        a = {k: self.c(i) for k, i in (("hog", 4), ("busy", 7), ("gp0wait", 25),
                                       ("gpurd", 24), ("dmairq", 62), ("ch4", 63),
                                       ("held", 2), ("clk", 0))}
        time.sleep(0.5)
        b = {k: self.c(i) for k, i in (("hog", 4), ("busy", 7), ("gp0wait", 25),
                                       ("gpurd", 24), ("dmairq", 62), ("ch4", 63),
                                       ("held", 2), ("clk", 0))}
        d = {k: (b[k] - a[k]) & 0xFFFFFFFF for k in a}
        print("    over %.1f Mclk: hog %d  busy %d  gp0wait %d  gpuread %d  "
              "dma-irqs %d  ch4-done %d  cpu-held %d"
              % (d["clk"] / 1e6, d["hog"], d["busy"], d["gp0wait"], d["gpurd"],
                 d["dmairq"], d["ch4"], d["held"]))
        print("    drive %08x   last drive commands:" % self.rd(0xAC))
        for s in self.trace(10):
            print("      " + s)


def main():
    secs = float(sys.argv[1]) if len(sys.argv) > 1 else 300
    b = Board()
    if "--no-reboot" not in sys.argv:
        b.reboot()
        print("rebooted; waiting for the game to draw", flush=True)
        t = time.time()
        while time.time() - t < 180:
            a = b.c(7); time.sleep(2.0)
            if ((b.c(7) - a) & 0xFFFFFFFF) > 100000:
                break
        else:
            print("it never started drawing"); return 1
        print("drawing after %.0f s" % (time.time() - t), flush=True)

    t0 = time.time()
    prev = None
    prev_snap = None
    persec = []
    same = 0
    stalls = []
    gaps = []
    live_secs = 0
    flip_prev = None
    last_flip = time.time()
    next_tick = time.time() + 1.0
    while time.time() - t0 < secs:
        v = b.rd(0x6C) & 0x3FF
        now = time.time()
        if flip_prev is not None and v != flip_prev:
            gaps.append((now - last_flip, now - t0)); last_flip = now
        flip_prev = v
        if now >= next_tick:
            next_tick = now + 1.0
            # Everything that could explain this second's frame times, sampled
            # together: a frame rate on its own says the machine is slow, not
            # what it is waiting for.
            snap = (b.c(0), b.c(16), b.c(22), b.c(7), b.c(2), b.c(4), b.c(33), b.c(34), b.c(35), b.c(18))
            if prev_snap is not None:
                d = [(y - x) & 0xFFFFFFFF for x, y in zip(prev_snap, snap)]
                clk = d[0] or 1
                recent = [x[0] for x in gaps if now - x[1] - t0 < 1.0]
                persec.append((now - t0,
                               (sum(recent) / len(recent) * 1e3) if recent else 0.0,
                               len(recent),
                               100.0 * d[3] / clk, 100.0 * d[4] / clk, 100.0 * d[5] / clk,
                               d[1], d[2],
                               100.0 * d[6] / clk, 100.0 * d[7] / clk, 100.0 * d[8] / clk,
                               100.0 * d[9] / clk))
            prev_snap = snap
            cur = (snap[1], snap[2])
            if prev is not None:
                moved = cur != prev
                if moved:
                    if same >= 3:
                        print("%6.0fs  moving again after %d s stopped" % (now - t0, same), flush=True)
                        stalls[-1] = (stalls[-1][0], same)
                    same = 0
                    live_secs += 1
                else:
                    same += 1
                    if same == 3:
                        print("%6.0fs  THE SCENE STOPPED -- same pixels and primitives "
                              "three seconds running" % (now - t0), flush=True)
                        stalls.append((now - t0, None))
                        b.why()
            prev = cur

    print()
    print("watched %.0f s; the scene was advancing for %d of them  (%d link drops ridden out)"
          % (secs, live_secs, b.drops))

    # A level load is not a slow frame. The game stops drawing, the picture
    # holds, and the display keeps flipping -- counting those seconds as frame
    # times would put a four-second "frame" in the sample and make the 1% low
    # meaningless. So the pacing is measured only over the stretches where the
    # scene was actually advancing, and the loads are reported separately,
    # which is what a person watching would separate them into as well.
    def in_a_stall(t):
        for at, dur in stalls:
            if at - 4.0 <= t <= at + (dur if dur else 1e9) + 1.0:
                return True
        return False

    def report(label, sample):
        if len(sample) <= 20:
            print("  %s: only %d frames, too few to report" % (label, len(sample)))
            return
        q = sorted(sample); n = len(q)
        print("  %-18s %5d frames   median %5.1f ms -> %4.1f fps   1%% low %6.1f ms -> %4.1f fps   worst %6.0f ms"
              % (label, n, q[n // 2] * 1e3, 1 / q[n // 2],
                 q[int(n * .99) - 1] * 1e3, 1 / q[int(n * .99) - 1], q[-1] * 1e3))

    report("everything", [x[0] for x in gaps])
    play = [x[0] for x in gaps if not in_a_stall(x[1])]
    report("playing only", play)

    # A PlayStation flips on a vertical blank, so every frame time is a whole
    # number of 16.7 ms periods. Which one it is says everything: two is the
    # 30 fps the game is written for, three is 20, four is 15. A median hides
    # that; this does not.
    if play:
        hist = {}
        for g0 in play:
            k = max(1, int(round(g0 / 0.016683)))
            hist[k] = hist.get(k, 0) + 1
        print()
        print("  frame times as vertical blanks (playing only):")
        for k in sorted(hist):
            if hist[k] * 200 < len(play):
                continue
            print("    %2d vblanks = %5.1f fps : %5d frames  %5.1f%%"
                  % (k, 60.0 / k, hist[k], 100.0 * hist[k] / len(play)))

    if persec:
        import csv
        # Timestamped, and a copy at the plain name for convenience. The plain
        # one used to be all there was, so the next run overwrote the baseline
        # the change was supposed to be judged against -- and with no version
        # control in this tree there was no getting it back.
        stamp = time.strftime("%Y%m%d-%H%M%S")
        out = os.path.join(OUTDIR, "ps1watch-%s.csv" % stamp)
        with open(out, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["t", "mean_frame_ms", "flips", "engine_busy_pct", "cpu_held_pct",
                        "dma_hog_pct", "pixels", "prims", "raster_busy_pct",
                        "raster_dst_miss_pct", "raster_clut_pct", "raster_texel_pct"])
            for row in persec:
                w.writerow(["%.1f" % row[0], "%.1f" % row[1], row[2],
                            "%.1f" % row[3], "%.1f" % row[4], "%.1f" % row[5],
                            row[6], row[7], "%.1f" % row[8], "%.1f" % row[9], "%.1f" % row[10],
                            "%.1f" % row[11]])
        try:
            import shutil
            shutil.copyfile(out, os.path.join(OUTDIR, "ps1watch.csv"))
        except Exception:
            pass
        print("  per-second detail written to %s" % out)
    for at, dur in stalls:
        print("  stopped at %.0f s, %s" % (at, "for %d s" % dur if dur else "and never restarted"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
