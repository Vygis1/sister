#!/usr/bin/env python3
"""The NTSC palette table in sim/tb_a26.v, and how it was made.

The TIA's colour byte is a hue (bits 7:4, 0 grey then 15 hues a chroma phase step
apart) and a luminance (bits 3:1, eight levels). The table is that encoder run
through the standard YIQ-to-RGB matrix: luminance maps to Y, the hue to a phase
in the I/Q plane starting at gold (hue 1) and turning through orange, red,
purple, blue, cyan and green back toward gold. This is a yardstick for looking
at frames, not a measurement of any television; the bench never compares RGB.

    python tools/a26/ntsc_palette.py        prints the Verilog case lines
"""
import math

STEP = 24.5          # degrees of chroma phase per hue step
START = -45.0        # hue 1 sits at gold: +I, a little -Q
SAT = 0.30


def rgb(color7):
    hue = color7 >> 3
    lum = color7 & 7
    y = (lum * 2 + 1) / 16.0
    if hue == 0:
        i = q = 0.0
    else:
        a = math.radians(START + STEP * (hue - 1))
        i, q = SAT * math.cos(a), SAT * math.sin(a)
    r = y + 0.956 * i + 0.621 * q
    g = y - 0.272 * i - 0.647 * q
    b = y - 1.106 * i + 1.703 * q
    clip = lambda v: max(0, min(255, int(round(v * 255))))
    return clip(r), clip(g), clip(b)


if __name__ == '__main__':
    for c in range(128):
        r, g, b = rgb(c)
        print("\t\t7'd%-3d: pal = 24'h%02X%02X%02X;" % (c, r, g, b))
