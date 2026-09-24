"""Put a Master System cartridge on the board and run it.

    python tools/smsload.py sim/roms/z80/smstest.sms

The cartridge shares the same block RAM the NES uses, and which machine is
running is a register write -- so this and a .nes file are the same operation
with a different core selected.
"""
import sys, struct, time
sys.path.insert(0, "pc")
from fpgalink import Link

NES_CTRL, NES_CONSOLE = 0x0008_0004, 0x0008_0020
NES_FRAME, NES_PC = 0x0008_0010, 0x0008_0028
NES_PRG, VID_CTRL, VID_FB = 0x0009_0000, 0x0006_0004, 0x0010_0000
FB_WORDS = 320 * 240 // 4

rom = open(sys.argv[1], "rb").read()
link = Link("192.168.178.50", timeout=1.0, retries=6)
print(f"{sys.argv[1]}: {len(rom) // 1024} kB")

rom = rom.ljust((len(rom) + 3) // 4 * 4, bytes(1))
words = list(struct.unpack(f"<{len(rom)//4}I", rom))

link.write(NES_CTRL, 0)
for i in range(0, len(words), 16384):
    link.write_block(NES_PRG + (i // 16384) * 0x0001_0000, words[i:i + 16384])

link.write(NES_CONSOLE, 1)            # the Master System slot, not the bare Z80
link.write(VID_CTRL, 0b11)            # framebuffer takes the console's pixels
link.write(NES_CTRL, 1)
print("  running")

time.sleep(2.0)
print(f"  frames={link.read(NES_FRAME)}  PC={link.read(NES_PC):#06x}")

data = b"".join(struct.pack("<I", w) for w in link.read_block(VID_FB, FB_WORDS))
open("build/sms_frame.bin", "wb").write(data)
print(f"  captured a frame: {len(set(data))} distinct colours")
