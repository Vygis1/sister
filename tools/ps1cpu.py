"""Where the processor's clocks go, and whether the missing speed is ours or the BIOS's.

    python tools/ps1cpu.py [samples]

The core runs at 50 MHz, so it only needs 0.68 instructions a clock to match a
real R3000A's 33.9 MIPS -- which is that chip's theoretical peak, one
instruction per clock at 33.87 MHz, and not something real code sustains.

The floor of this core is one clock an instruction, plus two for a load (the
request goes out in S_MEMW and the word is collected in S_MEMR) and one for a
store. Everything above that floor is stall. This prints the floor, the stall,
and what each would be worth -- and samples repeatedly, because the answer
depends entirely on what the BIOS is doing: polling a busy drawing engine is
stall the real machine has too.
"""
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pc"))
import fpgalink as fl
# ctrl 0xEC: 'pace' on the command line holds the CPU to the console's clock
# (bit 12; the default is the board's), 'fast' lets the GPU past its fill rate (bit 13)
FLAGS = (0x1000 if 'pace' in sys.argv[1:] else 0) | (0x2000 if 'fast' in sys.argv[1:] else 0)
sys.argv = [a for a in sys.argv if a not in ('fast', 'pace')]

N = 0x0008_0000
BOARD = fl.DEFAULT_HOST
SEL = {"clocks": 0, "instructions": 3, "held up": 2, "engine busy": 7,
       "loads": 10, "stores": 11, "load clocks": 12, "store clocks": 13}


def snap(link):
    out = {}
    for name, i in SEL.items():
        link.write(N + 0xEC, i | FLAGS)
        out[name] = link.read(N + 0xEC)
    return out


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 6
    link = fl.Link(BOARD, 5005, timeout=0.6, retries=3)
    print("  %-6s %-7s %-6s %-7s %-7s %-7s %s"
          % ("MIPS", "clk/ins", "engine", "ld clks", "st clks", "stall", "what it would be with no stall"))
    for _ in range(n):
        a = snap(link); t0 = time.time(); time.sleep(1.5); b = snap(link)
        dt = time.time() - t0
        d = {k: (b[k] - a[k]) & 0xFFFFFFFF for k in a}
        clk = d["clocks"] or 1
        ins = d["instructions"] or 1
        mips = d["instructions"] / dt / 1e6
        cpi = float(clk) / ins
        stall = float(d["held up"]) / ins
        ldc = float(d["load clocks"]) / (d["loads"] or 1)
        stc = float(d["store clocks"]) / (d["stores"] or 1)
        # the floor: one clock an instruction, two more for a load, one for a store
        floor = 1.0 + 2.0 * (d["loads"] / float(ins)) + 1.0 * (d["stores"] / float(ins))
        print("  %-6.1f %-7.3f %-6.0f%% %-7.2f %-7.2f %-7.3f %.1f MIPS (floor %.3f clk/ins)"
              % (mips, cpi, 100.0 * d["engine busy"] / clk, ldc, stc, stall,
                 mips * cpi / floor, floor))


if __name__ == "__main__":
    main()
