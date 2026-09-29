"""What the frame capture costs the machine, with the page being served.

    python tools/ps1capcost.py [seconds]

The capture has priority over the drawing engine for VRAM, so every clock it
spends is a clock the engine does not get -- and the user only ever sees the
machine through the page. These are the numbers to compare a change against,
because unlike a frame rate they do not depend on which level the attract cycle
happens to be in:

  capture running       counter 29, clocks with the scanout not idle
  capture read waiting  counter 53, clocks it asked for a line and had not got it
  clocks a line         the same, divided by the lines it actually read
"""
import os, sys, time, threading, urllib.request
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pc"))
import fpgalink as fl

N = 0x0008_0000
BOARD = fl.DEFAULT_HOST
SEL = {"clocks": 0, "engine busy": 7, "raster busy": 17, "CPU held": 2,
       "instructions": 3, "capture running": 29, "capture held": 30,
       "capture read waiting": 53, "capture line reads": 56,
       "vertical syncs": 49}

stop = False


def puller():
    while not stop:
        try:
            urllib.request.urlopen("http://127.0.0.1:8080/api/vid/frame", timeout=8).read()
        except Exception:
            time.sleep(0.05)


def main():
    global stop
    secs = float(sys.argv[1]) if len(sys.argv) > 1 else 20.0
    threading.Thread(target=puller, daemon=True).start()
    time.sleep(2)
    link = fl.Link(BOARD)

    def snap():
        o = {}
        for k, i in SEL.items():
            link.write(N + 0xEC, i)
            o[k] = link.read(N + 0xEC)
        return o

    a = snap(); time.sleep(secs); b = snap()
    d = {k: (b[k] - a[k]) & 0xFFFFFFFF for k in a}
    c = d["clocks"]
    print(f"over {c} clocks ({c / 50e6:.1f} s), page being served")
    for k in SEL:
        if k in ("clocks", "capture line reads", "vertical syncs", "instructions"):
            continue
        print(f"  {k:24s} {d[k]:11d}  {100.0 * d[k] / c:5.1f}%")
    lines = d["capture line reads"]
    print(f"  lines the capture read     {lines:11d}"
          f"   {d['capture running'] / max(lines,1):.1f} clocks each")
    print(f"  instructions              {d['instructions']:11d}"
          f"   {d['instructions'] / (c / 50e6) / 1e6:.1f} MIPS")
    stop = True


if __name__ == "__main__":
    main()
