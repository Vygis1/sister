"""What the instruction-fetch run is worth, A/B on the board.

    python tools/ps1irun.py [seconds]

The processor's cache fetches a RUN of four lines for an instruction fetch
(ps1_top, `ic_run`). ctrl 0xEC bit 18 turns that off, so the same run of the
same scene can be measured both ways instead of comparing two attract cycles,
which do not compare (see [[ps1-palette-is-the-speed-cap]]).

The number that matters is CLOCKS AN INSTRUCTION -- it does not depend on which
level the game happens to be in, which a frame rate very much does.
"""
import sys, time, threading, urllib.request
sys.path.insert(0, r"C:/fpga/pc")
import fpgalink as fl

N = 0x0008_0000
BOARD = "192.168.178.50"
NO_IRUN = 1 << 18
SEL = {"clocks": 0, "instructions": 3, "waiting for an instruction": 9,
       "loads": 10, "collecting loads": 12, "stores": 11, "on stores": 13,
       "CPU held": 2, "engine busy": 7, "memory transactions": 1}

stop = False


def puller():
    while not stop:
        try:
            urllib.request.urlopen("http://127.0.0.1:8080/api/vid/frame", timeout=8).read()
        except Exception:
            time.sleep(0.05)


def run(link, secs, flags, label):
    def p(i):
        link.write(N + 0xEC, i | flags)
        return link.read(N + 0xEC)
    a = {k: p(i) for k, i in SEL.items()}
    time.sleep(secs)
    b = {k: p(i) for k, i in SEL.items()}
    d = {k: (b[k] - a[k]) & 0xFFFFFFFF for k in a}
    c, ins = d["clocks"], d["instructions"]
    print(f"  {label}")
    print(f"    {ins/(c/50e6)/1e6:5.2f} MIPS   {c/max(ins,1):.3f} clocks an instruction")
    print(f"    waiting for an instruction {100.0*d['waiting for an instruction']/c:5.2f}% of all clocks")
    print(f"    a load costs {d['collecting loads']/max(d['loads'],1):.2f} clocks,"
          f" a store {d['on stores']/max(d['stores'],1):.2f}")
    print(f"    memory transactions {d['memory transactions']:,}")
    return c / max(ins, 1), 100.0 * d["waiting for an instruction"] / c


def main():
    global stop
    secs = float(sys.argv[1]) if len(sys.argv) > 1 else 8.0
    threading.Thread(target=puller, daemon=True).start()
    time.sleep(2)
    link = fl.Link(BOARD)
    rows = []
    for i in range(3):
        rows.append(("run on ", run(link, secs, 0, "instruction fetches ask for a run")))
        rows.append(("run off", run(link, secs, NO_IRUN, "one line at a time (ctrl 0xEC bit 18)")))
    link.write(N + 0xEC, 0)
    on = [r[1][0] for r in rows if r[0] == "run on "]
    off = [r[1][0] for r in rows if r[0] == "run off"]
    wn = [r[1][1] for r in rows if r[0] == "run on "]
    wf = [r[1][1] for r in rows if r[0] == "run off"]
    print()
    print(f"  clocks an instruction: run on {sum(on)/len(on):.3f}   off {sum(off)/len(off):.3f}"
          f"   -> {100.0*(sum(off)/len(off)-sum(on)/len(on))/(sum(off)/len(off)):+.1f}%")
    print(f"  waiting for an instruction: on {sum(wn)/len(wn):.2f}%   off {sum(wf)/len(wf):.2f}%")
    stop = True


if __name__ == "__main__":
    main()
