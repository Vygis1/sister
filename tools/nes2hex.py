"""Split a .nes file into PRG and CHR hex images for $readmemh.

    python tools/nes2hex.py sim/roms/01-vbl_basics.nes

Writes sim/roms/test_prg.hex and test_chr.hex, and prints the header fields the
testbench needs (mirroring especially -- getting it backwards makes scrolling
wrap the wrong way, which looks like a rendering bug rather than a config one).
"""
import sys
from pathlib import Path

src = Path(sys.argv[1])
d = src.read_bytes()
assert d[:4] == b"NES\x1a", "not an iNES file"
prg_banks, chr_banks = d[4], d[5]
mapper = (d[6] >> 4) | (d[7] & 0xF0)
mirror_v = d[6] & 1
print(f"{src.name}: PRG {prg_banks}x16K, CHR {chr_banks}x8K, mapper {mapper}, "
      f"mirroring {'vertical' if mirror_v else 'horizontal'}")
KNOWN = {0: "NROM", 1: "MMC1", 2: "UxROM", 4: "MMC3"}
if mapper not in KNOWN:
    have = ", ".join(f"{n} {nm}" for n, nm in sorted(KNOWN.items()))
    print(f"  warning: mapper {mapper} is not implemented (have: {have})")

prg = d[16:16 + prg_banks * 16384]
chr_ = d[16 + prg_banks * 16384:][:chr_banks * 8192]

# NROM-128 mirrors its single 16 KB bank into both halves of $8000-$FFFF.
if prg_banks == 1:
    prg = prg + prg
if not chr_:
    chr_ = bytes(8192)          # CHR RAM carts start blank

out = src.parent
(out / "test_prg.hex").write_text("".join(f"{b:02X}\n" for b in prg))
(out / "test_chr.hex").write_text("".join(f"{b:02X}\n" for b in chr_))
# The testbench needs to know which chip to behave as, and how big the ROM is:
# MMC3's two fixed windows are the LAST two banks, so the size is part of the
# address decode rather than just a capacity.
prg_last = max(len(prg) // 8192 - 1, 0)
(out / "test_cfg.txt").write_text(str(mirror_v) + chr(10) + str(mapper) + chr(10) + str(prg_last) + chr(10))
print(f"  wrote {len(prg)} PRG + {len(chr_)} CHR bytes, "
      f"mapper {mapper}, {prg_last + 1} 8K banks")
