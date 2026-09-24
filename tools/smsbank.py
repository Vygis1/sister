"""Assemble a Master System cartridge that proves its own banking.

    python tools/smsbank.py sim/roms/z80/smsbank.sms

128 kB in eight 16 kB banks. Each bank carries its own number near the end of
it, at offset $3FF0 -- which is address $BFF0 once the bank is paged in at
$8000.

The program pages every bank in turn and reads that byte back. It turns the
display on only if all eight answered with their own number. So a screen with
anything on it means banking works, and a black one means it does not, and
there is no third outcome to interpret.

The point is the FAILURE it catches. A cartridge that fits in 64 kB cannot tell
a working address path from one that quietly drops the top two bits, because
every address it uses is under the fold. This one spends most of its time above
it: bank 5 lives at $14000, and an address path that keeps only sixteen bits
maps that to $4000 and reads bank 1 instead.
"""
import sys

BANK = 16 * 1024
BANKS = 8
SIG = 0x3FF0                 # where each bank keeps its number

code = bytearray()
def b(*xs): code.extend(xs)

def vdp_reg(r, v):
    b(0x3E, v, 0xD3, 0xBF)
    b(0x3E, 0x80 | r, 0xD3, 0xBF)

def vdp_addr(a, cmd):
    b(0x3E, a & 0xFF, 0xD3, 0xBF)
    b(0x3E, cmd | (a >> 8), 0xD3, 0xBF)

def vdp_data(v):
    b(0x3E, v, 0xD3, 0xBE)

b(0xC3, 0x40, 0x00)                      # JP $0040
while len(code) < 0x40:
    b(0x00)

b(0xF3)                                  # DI
b(0x31, 0xF0, 0xDF)                      # LD SP,$DFF0

vdp_reg(0, 0x04)     # mode 4
vdp_reg(1, 0x00)     # display off for now
vdp_reg(2, 0xFF)     # name table at $3800
vdp_reg(5, 0xFF)
vdp_reg(6, 0xFF)
vdp_reg(7, 0x00)
vdp_reg(8, 0x00)
vdp_reg(9, 0x00)
vdp_reg(10, 0xFF)

# Palette: entry 1 bright white, entry 16 (the backdrop) black, so "it drew
# something" and "it did not" are the two most different things a screen can be.
vdp_addr(0, 0xC0)
for v in [0x00, 0x3F, 0x0C, 0x30, 0x3F, 0x15, 0x2A, 0x00]:
    vdp_data(v)
vdp_addr(16, 0xC0)
vdp_data(0x00)

# Tile 1: solid colour 1.
vdp_addr(0x20, 0x40)
for _ in range(8):
    vdp_data(0xFF)
    vdp_data(0x00)
    vdp_data(0x00)
    vdp_data(0x00)

# Name table: 32 x 28 cells of tile 1.
vdp_addr(0x3800, 0x40)
b(0x01, 0x80, 0x03)                      # LD BC,896
fill = len(code)
b(0x3E, 0x01, 0xD3, 0xBE)
b(0x3E, 0x00, 0xD3, 0xBE)
b(0x0B)
b(0x78, 0xB1)
b(0x20, (fill - (len(code) + 2)) & 0xFF)

# --- the actual test --------------------------------------------------------
# Page each bank in at $8000 and read the byte it signs itself with. The bank
# number is also written to $C020 as it goes, so a testbench that wants to say
# WHICH bank failed can, without having to work it out from a black screen.
b(0x0E, 0x00)                            # LD C,0
b(0x06, BANKS)                           # LD B,8
walk = len(code)
b(0x79)                                  # LD A,C
b(0x32, 0x20, 0xC0)                      # LD ($C020),A  -- how far it got
b(0x32, 0xFF, 0xFF)                      # LD ($FFFF),A  -- page it in
b(0x3A, 0xF0, 0xBF)                      # LD A,($BFF0)  -- its signature
b(0xB9)                                  # CP C
b(0x20, 0x06)                            # JR NZ,stop
b(0x0C)                                  # INC C
b(0x10, (walk - (len(code) + 2)) & 0xFF) # DJNZ walk

# Every bank answered for itself.
vdp_reg(1, 0x40)                         # display on
stop = len(code)
b(0x18, (stop - (len(code) + 2)) & 0xFF) # JR stop

assert len(code) < SIG, f"code is {len(code)} bytes and would collide with the signature"

rom = bytearray(BANK * BANKS)
rom[0:len(code)] = code
for n in range(BANKS):
    rom[n * BANK + SIG] = n

open(sys.argv[1], "wb").write(rom)
print(f"{sys.argv[1]}: {len(code)} bytes of code, "
      f"{BANKS} banks of {BANK // 1024} kB, signatures at ${SIG:04X}")
