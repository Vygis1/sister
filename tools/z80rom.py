"""Turn a CP/M .COM file into hex for $readmemh.

    python tools/z80rom.py sim/roms/z80/prelim.com

Writes sim/roms/z80/test.hex, which tb_z80 loads at $0100. Verilog's
$readmemh cannot read a binary, and neither can it be told an offset from
inside the file, so the offset lives in the $readmemh call instead.
"""
import sys
from pathlib import Path

src = Path(sys.argv[1])
d = src.read_bytes()
out = src.parent / "test.hex"
out.write_text("".join(f"{b:02X}\n" for b in d))
print(f"{src.name}: {len(d)} bytes -> {out}, loads at $0100..${0x100+len(d)-1:04X}")
