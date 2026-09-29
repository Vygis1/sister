"""Load a cartridge onto the board and read frames back, with no browser involved.

    python tools/playtest.py "path/to/game.nes"

The web UI does the same thing, so when a game misbehaves this says whether the
fault is in the console or in the page in front of it.
"""
import os, sys, struct, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pc"))
from fpgalink import Link, DEFAULT_HOST

NES_CTRL, NES_JOY1 = 0x0008_0004, 0x0008_0008
NES_FRAME, NES_PC, NES_NMI = 0x0008_0010, 0x0008_0014, 0x0008_0018
NES_PRG, NES_CHR = 0x0009_0000, 0x000D_0000
NES_MAPPER, NES_CONSOLE = 0x0008_001C, 0x0008_0020
VID_CTRL, VID_FB = 0x0006_0004, 0x0010_0000
FB_WORDS = 320 * 240 // 4

link = Link(DEFAULT_HOST, timeout=1.0, retries=6)

rom = open(sys.argv[1], "rb").read()
assert rom[:4] == b"NES\x1a", "not an iNES file"
prg_banks, chr_banks = rom[4], rom[5]
mirror_v = rom[6] & 1
prg = rom[16:16 + prg_banks * 16384]
if prg_banks == 1:
    prg = prg + prg
chr_ = rom[16 + prg_banks * 16384:][:chr_banks * 8192] or bytes(8192)
mapper = (rom[6] >> 4) | (rom[7] & 0xF0)
# Pad to whole 32-bit words; do not truncate -- an MMC3 cartridge is
# many times bigger than the window the CPU sees.
prg = prg.ljust((len(prg) + 3) // 4 * 4, bytes(1))
chr_ = chr_.ljust((len(chr_) + 3) // 4 * 4, bytes(1))
prg_last = max(len(prg) // 8192 - 1, 0)
print(f"{sys.argv[1]}: {prg_banks}x16K PRG, {chr_banks}x8K CHR, "
      f"{'vertical' if mirror_v else 'horizontal'} mirroring, mapper {mapper}")

words = lambda b: list(struct.unpack(f"<{len(b)//4}I", b))

link.write(NES_CTRL, 0)                     # hold in reset while the cart changes
# Say which machine this is. The board keeps running whichever core it was last
# told to, so loading a .nes without this leaves a Master System staring at it
# -- which looks exactly like a broken NES.
link.write(NES_CONSOLE, 0)
def write_pages(base, ws):
    for i in range(0, len(ws), 16384):
        link.write_block(base + (i // 16384) * 0x0001_0000, ws[i:i + 16384])

write_pages(NES_PRG, words(prg))
write_pages(NES_CHR, words(chr_))
link.write(NES_MAPPER, (prg_last << 8) | mapper)
link.write(VID_CTRL, 0b11)                  # framebuffer takes NES pixels
link.write(NES_CTRL, (2 if mirror_v else 0) | 1)
print("loaded, running")

def frame(path):
    data = b"".join(struct.pack("<I", w)
                    for w in link.read_block(VID_FB, FB_WORDS))
    open(path, "wb").write(data)
    return data

def status(tag):
    print(f"  {tag:14s} frame={link.read(NES_FRAME):6d}  "
          f"PC=0x{link.read(NES_PC):04X}  NMI={link.read(NES_NMI):6d}")

time.sleep(1.0); status("booted")
link.write(NES_JOY1, 0x08); time.sleep(0.3)      # Start
link.write(NES_JOY1, 0x00)
time.sleep(4.0); status("in the level")
a = frame("build/hw_a.bin")

link.write(NES_JOY1, 0x80)                        # hold Right
time.sleep(1.5); status("holding right")
b = frame("build/hw_b.bin")
link.write(NES_JOY1, 0x00)

print(f"  the two frames differ in {sum(x != y for x, y in zip(a, b))} of {len(a)} bytes")
