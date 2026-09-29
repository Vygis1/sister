"""Why some frames make 30 and others fall to 20, out of a ps1watch run.

    python tools/ps1why.py [build/console/ps1watch-YYYYmmdd-HHMMSS.csv]

tools/ps1watch.py logs, every second, the frame time and what the machine was
doing to earn it. This reads that back and splits the seconds into the ones
that mostly made two vertical blanks and the ones that mostly took three, then
reports both NORMALISED PER FRAME and PER PIXEL.

Per pixel is the number that survives a change of scene. Crash's attract cycle
visits different levels, so two runs of the same length measure different
workloads, and comparing their frame-rate histograms measures the cycle rather
than the machine -- which is exactly the mistake that made a measured
improvement look like a regression once already.
"""
import csv, sys, glob, os

TWO_VBLANK_CLOCKS = 50e6 / 30.0     # what a 30 fps frame has to fit in


def main():
    if len(sys.argv) > 1:
        path = sys.argv[1]
    else:
        runs = sorted(glob.glob(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "console", "ps1watch-*.csv")), key=os.path.getmtime)
        if not runs:
            print("no ps1watch run found"); return 1
        path = runs[-1]
    print("  %s" % os.path.basename(path))
    rows = list(csv.DictReader(open(path)))
    g = lambda r, k: float(r.get(k) or 0)
    live = [r for r in rows if int(r["flips"]) > 10 and g(r, "pixels") > 0]
    if not live:
        print("  no live seconds in this run"); return 1
    fast = [r for r in live if g(r, "mean_frame_ms") < 40]
    slow = [r for r in live if g(r, "mean_frame_ms") >= 45]

    def block(label, grp):
        if not grp:
            print("  %-14s none" % label); return
        px = sum(g(r, "pixels") for r in grp)
        pr = sum(g(r, "prims") for r in grp)
        fl = sum(int(r["flips"]) for r in grp)
        busy = sum(g(r, "engine_busy_pct") / 100.0 * 50e6 for r in grp)
        held = sum(g(r, "cpu_held_pct") / 100.0 * 50e6 for r in grp)
        print("  %-14s %4d s   %7.0f px/frame  %6.0f prims/frame  %5.1f px/prim"
              % (label, len(grp), px / fl, pr / fl, px / max(pr, 1)))
        print("                 engine %8.0f clocks/frame (%.0f%% of a 30 fps frame)"
              "   %5.2f clocks/px   %6.0f clocks/prim"
              % (busy / fl, 100.0 * (busy / fl) / TWO_VBLANK_CLOCKS, busy / px, busy / max(pr, 1)))
        print("                 cpu held %6.0f clocks/frame   raster stalls of all clocks:"
              "  texel %.1f%%  palette %.1f%%  destination %.1f%%"
              % (held / fl,
                 sum(g(r, "raster_texel_pct") for r in grp) / len(grp),
                 sum(g(r, "raster_clut_pct") for r in grp) / len(grp),
                 sum(g(r, "raster_dst_miss_pct") for r in grp) / len(grp)))

    block("made 30 fps", fast)
    block("fell to 20", slow)

    px = sum(g(r, "pixels") for r in live)
    busy = sum(g(r, "engine_busy_pct") / 100.0 * 50e6 for r in live)
    fl = sum(int(r["flips"]) for r in live)
    print()
    print("  WHOLE RUN: %.2f engine clocks a pixel, %.0f px a frame, "
          "%.0f engine clocks a frame (a 30 fps frame has %.0f)"
          % (busy / px, px / fl, busy / fl, TWO_VBLANK_CLOCKS))
    print("  Compare runs on CLOCKS A PIXEL. The rest moves with the scene.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
