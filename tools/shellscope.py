"""Capture what the shell's pins actually do, and draw it.

    python tools/shellscope.py esp        trigger on the ESP32 selecting us
    python tools/shellscope.py flash      trigger on the shell selecting the flash

The shell carries the same logic analyser the console image has, pointed at the
only two things it talks to. Both of its failure modes -- a flash that answers
nothing and a link that returns zeros -- are questions about whether pins move
and in what order, and a counter cannot tell "never driven" from "driven and
ignored". A waveform can.

Bits, as wired in shell_top:

    0 flash_sck   1 flash_mosi   2 flash_cs_n   3 flash_miso
    4 esp_sclk    5 esp_mosi     6 esp_cs_n     7 esp_miso
"""

import sys
import time
import os

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pc"))
import fpgalink as fl

LA = 0x0002_0000
LABUF = 0x0003_0000
LA_CTRL, LA_STATUS = LA + 0x04, LA + 0x08
LA_CHAN, LA_DIV, LA_DEPTH, LA_PRE = LA + 0x0C, LA + 0x10, LA + 0x14, LA + 0x18
LA_TMASK, LA_TVAL, LA_TRISE, LA_TFALL = LA + 0x1C, LA + 0x20, LA + 0x24, LA + 0x28

CTRL_ARM, CTRL_FORCE, CTRL_RESET = 1, 2, 4
ST_DONE = 4

NAMES = ["flash_sck", "flash_mosi", "flash_cs_n", "flash_miso",
         "esp_sclk", "esp_mosi", "esp_cs_n", "esp_miso"]

SHELL_CTRL = 0x0000_0010


def capture(link, fall_mask, depth=4096, divisor=0, pretrig=64):
    link.write(LA_CTRL, CTRL_RESET)
    link.write(LA_CHAN, 0xFF)
    link.write(LA_DIV, divisor)
    link.write(LA_DEPTH, depth)
    link.write(LA_PRE, pretrig)
    link.write(LA_TMASK, 0)
    link.write(LA_TVAL, 0)
    link.write(LA_TRISE, 0)
    link.write(LA_TFALL, fall_mask)
    link.write(LA_CTRL, CTRL_ARM)
    return link.read(LA_STATUS)


def wait_done(link, seconds):
    t0 = time.time()
    while time.time() - t0 < seconds:
        if link.read(LA_STATUS) & ST_DONE:
            return True
        time.sleep(0.02)
    return False


def draw(samples, which):
    """One row per signal, one column per sample, run-length collapsed.

    Collapsing matters: at 50 MHz against a 1 MHz SPI clock a single bit is
    fifty identical samples, and printing them all would hide the shape in the
    repetition.
    """
    runs = []
    for s in samples:
        v = s & 0xFF
        if runs and runs[-1][0] == v:
            runs[-1][1] += 1
        else:
            runs.append([v, 1])

    print(f"  {len(samples)} samples, {len(runs)} transitions")
    if len(runs) <= 1:
        print("  *** nothing changed for the whole capture")

    width = min(len(runs), 150)
    for bit in which:
        line = "".join("-" if (runs[i][0] >> bit) & 1 else "_"
                       for i in range(width))
        moved = len({(r[0] >> bit) & 1 for r in runs})
        print(f"  {NAMES[bit]:>11s} |{line}| {'moves' if moved > 1 else 'FLAT'}")

    print("  dwell (samples per transition):",
          " ".join(str(r[1]) for r in runs[:20]),
          "..." if len(runs) > 20 else "")


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "esp"
    link = fl.Link(fl.DEFAULT_HOST, timeout=1.0, retries=6)

    if link.read(0) != 0x5348454C:
        print("the board is not running the shell")
        return 1

    if what == "esp":
        print("waiting for the ESP32 to select us (it pings every 2 s)...")
        capture(link, fall_mask=1 << 6)
        ok = wait_done(link, 12)
        bits = [4, 5, 6, 7]
    else:
        print("arming, then asking the shell to read the flash id...")
        capture(link, fall_mask=1 << 2)
        time.sleep(0.05)
        link.write(SHELL_CTRL, 0)          # op 0 = read the chip id
        ok = wait_done(link, 5)
        bits = [0, 1, 2, 3]

    if not ok:
        print("  *** the trigger never fired: that pin never went low at all")
        # Capture anyway, to see whether ANYTHING is moving.
        link.write(LA_CTRL, CTRL_RESET)
        link.write(LA_CHAN, 0xFF)
        link.write(LA_DIV, 0)
        link.write(LA_DEPTH, 4096)
        link.write(LA_PRE, 0)
        for r in (LA_TMASK, LA_TVAL, LA_TRISE, LA_TFALL):
            link.write(r, 0)
        link.write(LA_CTRL, CTRL_ARM | CTRL_FORCE)
        if what == "flash":
            time.sleep(0.02)
            link.write(SHELL_CTRL, 0)
        wait_done(link, 5)

    n = link.read(LA_DEPTH)
    samples = link.read_block(LABUF, min(n, 2048))
    draw(samples, bits)
    return 0


if __name__ == "__main__":
    sys.exit(main())
