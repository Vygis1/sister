"""Harness drawing for the ESP32 link cable, for LCSC Cable / JLCPCB.

    python hardware/cable/make_drawing.py   ->  esp-link-harness.pdf / .png

The pinout is the one in hardware/CABLE.md; change it there and here together.
"""
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle, FancyBboxPatch

HERE = os.path.dirname(os.path.abspath(__file__))
REV, DATE, QTY, LEN = "A", "2026-10-05", 5, 100

# cavity, signal, colour (name, rgb), end-B label (LilyGO T8 pad)
WIRES = [
    (1, "SCLK",   ("YELLOW", "#e8c200"), "T8 pad 9  (IO18)"),
    (2, "MOSI",   ("GREEN",  "#2e9e3e"), "T8 pad 8  (IO23)"),
    (3, "MISO",   ("BLUE",   "#2a5bd7"), "T8 pad 7  (IO19)"),
    (4, "CS",     ("WHITE",  "#ffffff"), "T8 pad 10 (IO5)"),
    (5, "GND",    ("BLACK",  "#111111"), "T8 pad 12 (GND)"),
    (6, "GND",    ("BLACK",  "#111111"), "T8 pad 12 (GND)"),
    (7, "+5V",    ("RED",    "#d22424"), "T8 pad 15 (5V)"),
]
BLOCKED = 8

fig = plt.figure(figsize=(11.69, 8.27))          # A4 landscape
ax = fig.add_axes([0, 0, 1, 1]); ax.set_xlim(0, 297); ax.set_ylim(0, 210); ax.axis("off")
ink = "#222222"

def text(x, y, s, **k):
    k.setdefault("color", ink); k.setdefault("fontsize", 8); k.setdefault("family", "DejaVu Sans")
    ax.text(x, y, s, **k)

# frame + title block
ax.add_patch(Rectangle((8, 8), 281, 194, fill=False, lw=1.2, ec=ink))
ax.add_patch(Rectangle((189, 8), 100, 30, fill=False, lw=1, ec=ink))
for y in (16, 24, 31): ax.plot([189, 289], [y, y], color=ink, lw=0.6)
text(191, 33, "ESP32 LINK HARNESS  (fpga-console)", fontsize=9, weight="bold")
text(191, 26, f"7 wires, 2x4 2.54 mm crimp housing to tinned leads")
text(191, 18.5, f"Rev {REV}    {DATE}    Qty {QTY} pcs    Units: mm")
text(191, 10.5, "Drawn for LCSC Cable custom assembly", fontsize=7)

text(14, 194, "END A  -  2x4 housing, mating face view (looking into the cavities)", fontsize=9, weight="bold")
text(160, 194, "END B  -  stripped and tinned", fontsize=9, weight="bold")

# ---- END A: connector face, cavities 1..8 (1,3,5,7 top row / 2,4,6,8 bottom row)
p, cx0, cy0 = 11.0, 22, 140          # drawn pitch (not to scale)
ax.add_patch(FancyBboxPatch((cx0 - 3, cy0 - 3), 4 * p + 6, 2 * p + 6, boxstyle="round,pad=0.5",
                            fc="#2b2b2b", ec=ink, lw=1))
for cav in range(1, 9):
    col, row = (cav - 1) // 2, (cav - 1) % 2
    x, y = cx0 + col * p, cy0 + (1 - row) * p
    w = next((w for w in WIRES if w[0] == cav), None)
    if cav == BLOCKED:
        ax.add_patch(Rectangle((x + 1.5, y + 1.5), p - 3, p - 3, fc="#888888", ec="white", hatch="xxxx", lw=0.8))
        text(x + p / 2, y + p / 2, "KEY", ha="center", va="center", fontsize=6.5, color="black", weight="bold",
             bbox=dict(fc="white", ec="none", pad=0.6))
    else:
        ax.add_patch(Rectangle((x + 1.5, y + 1.5), p - 3, p - 3, fc=w[2][1], ec="white", lw=0.8))
        text(x + p / 2, y + p / 2, str(cav), ha="center", va="center", fontsize=9, weight="bold",
             color="black" if w[2][0] in ("YELLOW", "WHITE") else "white")
text(cx0 - 6, cy0 + 2 * p + 6, "▲ cavity 1 (top-left)", fontsize=7)
text(cx0 - 3, cy0 - 7, "Cavity 8: NO contact, blocked\nwith a polarizing key plug.", fontsize=7, va="top")

# ---- wires
xa, xb = 85, 205
ys = [176 - 8 * i for i in range(len(WIRES))]
for (cav, sig, (cname, rgb), endb), y in zip(WIRES, ys):
    ax.plot([xa, xb], [y, y], color="#555555", lw=3.6, solid_capstyle="butt")
    ax.plot([xa, xb], [y, y], color=rgb, lw=2.8, solid_capstyle="butt")
    ax.add_patch(Rectangle((xb, y - 0.9), 4, 1.8, fc="#c9c9c9", ec="#777777", lw=0.5))   # tinned tip
    text(xa - 2.5, y, f"{cav}", ha="center", va="center", fontsize=8, weight="bold")
    text((xa + xb) / 2, y + 1.6, f"{sig}  -  {cname}", ha="center", fontsize=7)
    text(xb + 6, y, endb, va="center", fontsize=7.5)
ax.add_patch(Rectangle((xa - 14, ys[-1] - 4), 9, ys[0] - ys[-1] + 8, fc="#2b2b2b", ec=ink))
text(xa - 9.5, ys[-1] - 6, "housing (side)", ha="center", va="top", fontsize=6.5)
# length dimension
yd = ys[-1] - 12
ax.annotate("", xy=(xa - 5, yd), xytext=(xb + 4, yd), arrowprops=dict(arrowstyle="<->", color=ink, lw=0.8))
for x in (xa - 5, xb + 4): ax.plot([x, x], [yd - 2, ys[-1] - 2], color=ink, lw=0.5)
text((xa + xb) / 2, yd - 4.5, f"L = {LEN} ± 3  (housing rear face to wire tip, all wires)", ha="center", fontsize=8)
ax.annotate("", xy=(xb, ys[0] + 4), xytext=(xb + 4, ys[0] + 4), arrowprops=dict(arrowstyle="<->", color=ink, lw=0.6))
text(xb + 2, ys[0] + 6, "3", ha="center", fontsize=7)

# ---- pin table
tx, ty = 14, 70
cols = [(0, "Cav."), (12, "Signal"), (32, "Colour"), (54, "End B (soldered by customer)"), (106, "Connects to (customer side)")]
text(tx, ty + 6, "PIN-OUT", fontsize=9, weight="bold")
for dx, h in cols: text(tx + dx, ty, h, weight="bold", fontsize=7.5)
ax.plot([tx, tx + 160], [ty - 1.5, ty - 1.5], color=ink, lw=0.6)
for i, (cav, sig, (cname, _), endb) in enumerate(WIRES + [(8, "-", ("-", None), "no wire, KEY")]):
    yy = ty - 6 - i * 5
    row = [str(cav), sig, cname, endb, f"QMTECH U2 pin {56 + cav}"]
    for (dx, _), v in zip(cols, row): text(tx + dx, yy, v, fontsize=7.5)

# ---- notes
nx, ny = 189, 100
notes = [
    "NOTES",
    "1. Housing: 2x4 position, 2.54 mm pitch, female crimp housing",
    "   (DuPont / TJC8-254 style). Equivalent parts acceptable.",
    "2. Contacts: matching female crimp terminals, tin or gold plated,",
    "   7 pcs. Cavity 8 empty and blocked (polarizing key).",
    "3. Wire: 26 AWG stranded, UL1007 or silicone, colours as table.",
    "4. Length 100 ± 3 mm, measured from housing rear face.",
    "5. End B: strip 3 mm, tin all 7 leads. No terminal.",
    "6. Loose bundle; spiral twist ~1 turn / 20 mm if offered.",
    "7. 100 % continuity test; no shorts between wires.",
    "8. Pack each harness separately.",
]
for i, n in enumerate(notes):
    text(nx, ny - i * 5.2, n, fontsize=7.5 if i else 9, weight="bold" if i == 0 else "normal")

for ext in ("pdf", "png"):
    fig.savefig(os.path.join(HERE, f"esp-link-harness.{ext}"), dpi=200 if ext == "png" else None)
print("written", os.path.join(HERE, "esp-link-harness.pdf"))
