"""Put a Master System cartridge where the simulation can read it.

    python tools/smshex.py sim/roms/z80/alexkidd.sms

xsim's $readmemh wants a text file and the testbench wants a fixed name, so
this is the one-line bridge between a .sms on disk and sim/roms/z80/game.hex.
"""
import sys, pathlib

src = pathlib.Path(sys.argv[1])
rom = src.read_bytes()
# Some dumps carry a 512-byte copier header. The giveaway is the size: a real
# cartridge is a power of two (or 3/4 of one), never a power of two plus 512.
if len(rom) % 1024 == 512:
    rom = rom[512:]
    print("  dropped a 512-byte copier header")

out = pathlib.Path("sim/roms/z80/game.hex")
out.write_text("".join("%02X\n" % b for b in rom))
print(f"{src.name}: {len(rom)//1024} kB -> {out}")
