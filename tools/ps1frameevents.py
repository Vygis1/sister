"""Where a frame goes: the board's frame event log, read and laid out per frame.

    python tools/ps1frameevents.py [seconds] [0xEC bits]   (0x1000: CPU at the console's clock)

ps1_top keeps the last 64 of these, each {type, 29-bit 50 MHz clock stamp}:
    0 flip (the displayed buffer changed)   1 display-list DMA start
    2 display-list DMA end                   3 drawing engine idle, nothing queued
    4 vertical sync
readable at ctrl 0x120 (write the index, read the entry) and 0x124 (next write
position). This follows the log for a while and reports, for each game frame
(flip to flip): how long it was in vsyncs, when the game kicked the display
list, how long the DMA ran, and when the drawing engine finished -- relative to
the flip that started the frame.

What it answers: does a slow frame wait for the PROCESSOR (the kick comes late)
or for the DRAWING ENGINE (the kick comes early, the drawing finishes late)?
"""
import os, sys, time, statistics
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pc"))
import fpgalink as fl

N = 0x0008_0000
CLK = 50e6
NAMES = {0: "flip", 1: "dma+", 2: "dma-", 3: "idle", 4: "vsync"}


def main():
    secs = float(sys.argv[1]) if len(sys.argv) > 1 else 10.0
    knob = int(sys.argv[2], 0) if len(sys.argv) > 2 else None
    l = fl.Link(fl.DEFAULT_HOST, 5005, timeout=0.05, retries=10)
    if knob is not None:
        l.write(N + 0xEC, knob)
    ev = []
    wp = l.read(N + 0x124) & 63
    t0 = time.time()
    lost = 0
    try:
        while time.time() - t0 < secs:
            nw = l.read(N + 0x124) & 63
            n = (nw - wp) & 63
            if n > 48: lost += 1
            for k in range(n):
                i = (wp + k) & 63
                l.write(N + 0x120, i)
                v = l.read(N + 0x120)
                ev.append((v >> 29, v & 0x1FFFFFFF))
            wp = nw
            time.sleep(0.01)
    finally:
        if knob is not None:
            l.write(N + 0xEC, 0)
    # unwrap the 29-bit clock
    t = []; base = 0; last = None
    for ty, c in ev:
        if last is not None and c < last: base += 1 << 29
        last = c
        t.append((ty, (base + c) / CLK * 1000.0))    # ms
    flips = [x for ty, x in t if ty == 0]
    frames = []
    for a, b in zip(flips, flips[1:]):
        inside = [(ty, x - a) for ty, x in t if a <= x < b and ty != 0]
        vs = sum(1 for ty, _ in inside if ty == 4)
        kicks = [x for ty, x in inside if ty == 1]
        ends = [x for ty, x in inside if ty == 2]
        idles = [x for ty, x in inside if ty == 3]
        frames.append(dict(len=b - a, vs=vs, kick=kicks[0] if kicks else None,
                           nkick=len(kicks), end=ends[-1] if ends else None,
                           idle=idles[-1] if idles else None))
    frames = [f for f in frames if f["len"] < 200]          # not loading screens
    if lost: print("(the log overran %d times: some frames are incomplete)" % lost)
    print("%d frames" % len(frames))
    if not frames: return
    def s(key, sub=None):
        v = [f[key] for f in (sub or frames) if f[key] is not None]
        return (statistics.median(v) if v else float("nan")), len(v)
    for label, sub in (("all", frames),
                       ("2-vsync frames (30 fps)", [f for f in frames if f["vs"] <= 2]),
                       ("3+ vsync frames (20 fps)", [f for f in frames if f["vs"] >= 3])):
        if not sub: continue
        print("  %-26s n=%-4d len %5.1f ms | kick at %5.1f ms | dma ends %5.1f | drawing done %5.1f | kicks/frame %.1f"
              % (label, len(sub), s("len", sub)[0], s("kick", sub)[0], s("end", sub)[0], s("idle", sub)[0],
                 statistics.mean(f["nkick"] for f in sub)))
    print("  first 12 frames (ms from the flip):")
    for f in frames[:12]:
        print("    len %5.1f  vs %d  kick %s  dma-end %s  drawn %s" % (
            f["len"], f["vs"],
            "%5.1f" % f["kick"] if f["kick"] is not None else "  -  ",
            "%5.1f" % f["end"] if f["end"] is not None else "  -  ",
            "%5.1f" % f["idle"] if f["idle"] is not None else "  -  "))


if __name__ == "__main__":
    main()
