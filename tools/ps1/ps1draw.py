"""Where the drawing engine's clocks go, and what a pixel costs.

    python tools/ps1/ps1draw.py [seconds]

The engine is either finishing its work inside a frame or it is not, and when it
is not the picture arrives in instalments -- which is what flicker looks like.
"Busy" alone does not say why, so these counters split its time into the box
walk and the four things it waits for, and divide by the pixels it actually put
down. Counters 16..23 in rtl/ps1_top.v.
"""
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "pc"))
import fpgalink as fl
# ctrl 0xEC: 'pace' on the command line holds the CPU to the console's clock
# (bit 12; the default is the board's), 'fast' lets the GPU past its fill rate (bit 13)
FLAGS = (0x1000 if 'pace' in sys.argv[1:] else 0) | (0x2000 if 'fast' in sys.argv[1:] else 0)
sys.argv = [a for a in sys.argv if a not in ('fast', 'pace')]

N = 0x0008_0000
BOARD = fl.DEFAULT_HOST

SEL = {
    "clocks":        0,
    "engine busy":   7,
    "pixels":       16,
    "box walk":     17,
    "waiting for the texel":       18,
    "waiting for the palette":     19,
    "waiting for what is under it":20,
    "waiting for the write":       21,
    "texel line held":             22,
    "destination line held":       23,
}


def snap(link):
    out = {}
    for name, i in SEL.items():
        link.write(N + 0xEC, i | FLAGS)
        out[name] = link.read(N + 0xEC)
    return out


def main():
    window = float(sys.argv[1]) if len(sys.argv) > 1 else 2.0
    link = fl.Link(BOARD, 5005, timeout=0.6, retries=3)
    a = snap(link)
    t0 = time.time()
    time.sleep(window)
    b = snap(link)
    dt = time.time() - t0
    d = {k: (b[k] - a[k]) & 0xFFFFFFFF for k in a}

    clk = d["clocks"] or 1
    px = d["pixels"] or 1
    print("  window %.2f s, %.1f M clocks (%.1f MHz)" % (dt, clk / 1e6, clk / dt / 1e6))
    print("  pixels drawn               %10d   %.2f M a second" % (d["pixels"], d["pixels"] / dt / 1e6))
    print("  clocks per pixel           %10.2f" % (float(clk) / px))
    print("  engine busy                %10d   %5.1f%% of clocks" % (d["engine busy"], 100.0 * d["engine busy"] / clk))
    print("  --- and busy doing what, per pixel ---")
    for k in ("box walk", "waiting for the texel", "waiting for the palette",
              "waiting for what is under it", "waiting for the write"):
        print("  %-30s %8.2f clocks   %5.1f%% of all clocks"
              % (k, float(d[k]) / px, 100.0 * d[k] / clk))
    print("  --- reads answered from a line already held ---")
    for k in ("texel line held", "destination line held"):
        print("  %-30s %8d   %5.2f per pixel" % (k, d[k], float(d[k]) / px))


if __name__ == "__main__":
    main()
