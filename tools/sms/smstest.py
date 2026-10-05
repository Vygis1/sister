"""Assemble a small Master System test cartridge.

    python tools/sms/smstest.py sim/roms/z80/smstest.sms

No commercial ROM is needed to find out whether the machine works, and a
hand-written one is better for the purpose: it draws something whose every
pixel is known in advance, so a testbench can check the picture rather than a
person squinting at it.

The program sets the VDP up the way any game does -- registers, palette, one
tile, a name table full of it -- turns the display on and stops.
"""
import sys

code = bytearray()
def b(*xs): code.extend(xs)

# The VDP is reached entirely through two ports. Setting a register means
# writing the value and then the register number with bit 7 set; setting an
# address means writing it low byte first with a command in the top two bits.
def vdp_reg(r, v):
    b(0x3E, v, 0xD3, 0xBF)              # LD A,v : OUT ($BF),A
    b(0x3E, 0x80 | r, 0xD3, 0xBF)       # LD A,$80|r : OUT ($BF),A

def vdp_addr(a, cmd):
    b(0x3E, a & 0xFF, 0xD3, 0xBF)
    b(0x3E, cmd | (a >> 8), 0xD3, 0xBF)

def vdp_data(v):
    b(0x3E, v, 0xD3, 0xBE)              # LD A,v : OUT ($BE),A

# --- reset entry ----------------------------------------------------------
# A jump out of the way, because the interrupt vector for mode 1 is $0038 and
# the reset entry is $0000 -- there are only 56 bytes between them.
b(0xC3, 0x80, 0x00)                      # JP $0080

while len(code) < 0x38:
    b(0x00)

# --- the interrupt handler, at $0038 ----------------------------------------
# Every Master System game hangs its whole frame loop off this, and the shape
# below is the shape all of them use: read the status port, and let bit 7
# decide whether this was the VBlank or the line counter.
#
# An earlier version of this handler read the port and threw the byte away. It
# still acknowledged the interrupt, because acknowledging happens on the VDP's
# side of the wire the moment the port is selected -- so it passed while the
# byte coming BACK was wrong. Every real game branches on that byte, and every
# real game therefore took the line-interrupt path forever and never drew
# anything. A test that reads a value and does not look at it is not a test.
b(0xF5)                                  # PUSH AF
b(0xDB, 0xBF)                            # IN A,($BF)   -- acknowledge and ask
b(0x07)                                  # RLCA         -- bit 7 into carry
b(0x30, 0x08)                            # JR NC,line
b(0x3A, 0x00, 0xC0)                      # LD A,($C000)
b(0x3C)                                  # INC A
b(0x32, 0x00, 0xC0)                      # LD ($C000),A -- VBlanks
b(0x18, 0x07)                            # JR done
# line:
b(0x3A, 0x01, 0xC0)                      # LD A,($C001)
b(0x3C)                                  # INC A
b(0x32, 0x01, 0xC0)                      # LD ($C001),A -- everything else
# done:
b(0xF1)                                  # POP AF
b(0xFB)                                  # EI
b(0xED, 0x4D)                            # RETI

while len(code) < 0x80:
    b(0x00)

b(0xF3)                                  # DI
b(0xED, 0x56)                            # IM 1
b(0x31, 0xF0, 0xDF)                      # LD SP,$DFF0

# Display off while everything is loaded: the CPU and the renderer share one
# VRAM port, so this is not optional on real hardware either.
vdp_reg(0, 0x04)     # mode 4
vdp_reg(1, 0x00)     # display off
vdp_reg(2, 0xFF)     # name table at $3800
vdp_reg(5, 0xFF)     # sprite table at $3F00
vdp_reg(6, 0xFF)     # sprite patterns at $2000
vdp_reg(7, 0x00)     # backdrop: entry 0 of the sprite palette
vdp_reg(8, 0x00)     # no scroll
vdp_reg(9, 0x00)
vdp_reg(10, 0xFF)    # line interrupt off

# Palette. Entry 1 is bright red, entry 2 bright green, 16 is dark blue so the
# backdrop is distinguishable from everything else.
vdp_addr(0, 0xC0)
for v in [0x00, 0x03, 0x0C, 0x30, 0x3F, 0x15, 0x2A, 0x00]:
    vdp_data(v)
vdp_addr(16, 0xC0)
vdp_data(0x20)       # backdrop, dark blue

# Tile 1: left half colour 1, right half colour 2. Plane 0 has the left four
# pixels, plane 1 the right four, so both planes have to be read in the right
# order for this to come out.
vdp_addr(0x20, 0x40)
for _ in range(8):
    vdp_data(0xF0)   # plane 0
    vdp_data(0x0F)   # plane 1
    vdp_data(0x00)
    vdp_data(0x00)

# Name table: every cell is tile 1. 32 columns x 28 rows is 896 entries of two
# bytes each -- 896 loop passes, not 896 bytes and not 3584. Getting this wrong
# ran the fill four times too long, wrapped past the top of the 16 kB and
# overwrote the tile at $0020, which looked exactly like a broken VDP.
vdp_addr(0x3800, 0x40)
b(0x01, 0x80, 0x03)                      # LD BC,896
loop = len(code)
b(0x3E, 0x01, 0xD3, 0xBE)                # LD A,1 : OUT ($BE),A
b(0x3E, 0x00, 0xD3, 0xBE)                # LD A,0 : OUT ($BE),A
b(0x0B)                                  # DEC BC
b(0x78, 0xB1)                            # LD A,B : OR C
b(0x20, (loop - (len(code) + 2)) & 0xFF) # JR NZ,loop

# A note on each of the three tone channels, and the noise channel silenced.
# Latch bytes carry the low four bits of a period; the byte after carries the
# top six. Volume is attenuation, so 0 is loudest.
def psg(v):
    b(0x3E, v, 0xD3, 0x7F)              # LD A,v : OUT ($7F),A

psg(0x80 | 0x00 | 0x0E)                  # channel 0 period low  = $0E
psg(0x00 | 0x00)                         # channel 0 period high = 0  -> ~450 Hz
psg(0x90 | 0x00)                         # channel 0 volume, loudest
psg(0xA0 | 0x0C)                         # channel 1 period low
psg(0x00 | 0x01)
psg(0xB0 | 0x04)                         # channel 1, quieter
psg(0xC0 | 0x08)                         # channel 2 period low
psg(0x00 | 0x02)
psg(0xD0 | 0x08)
psg(0xF0 | 0x0F)                         # noise off

# Display on AND the VBlank interrupt enabled -- bit 5 is what a game turns on
# once it is ready to be driven by the frame rate rather than by a busy loop.
vdp_reg(1, 0x60)

# Somewhere to record what the other two readable ports say. The V counter's
# high and low water marks start at the wrong ends so that anything real moves
# them.
b(0xAF)                                  # XOR A
b(0x32, 0x00, 0xC0)                      # LD ($C000),A  VBlank count
b(0x32, 0x01, 0xC0)                      # LD ($C001),A  other-interrupt count
b(0x32, 0x04, 0xC0)                      # LD ($C004),A  highest V seen
b(0x3E, 0xFF)                            # LD A,$FF
b(0x32, 0x05, 0xC0)                      # LD ($C005),A  lowest V seen
b(0xFB)                                  # EI

# The main loop watches the two ports a game watches: the line counter, which
# has to be moving, and the control pad, which has to say what is held. Both
# are reads, and reads are the thing that was broken.
here = len(code)
b(0xDB, 0x7E)                            # IN A,($7E)   -- the V counter
b(0x21, 0x04, 0xC0)                      # LD HL,$C004
b(0xBE)                                  # CP (HL)
b(0x38, 0x01)                            # JR C,+1
b(0x77)                                  # LD (HL),A    -- a new high
b(0x21, 0x05, 0xC0)                      # LD HL,$C005
b(0xBE)                                  # CP (HL)
b(0x30, 0x01)                            # JR NC,+1
b(0x77)                                  # LD (HL),A    -- a new low
b(0xDB, 0xDC)                            # IN A,($DC)   -- control pad 1
b(0x32, 0x06, 0xC0)                      # LD ($C006),A
b(0x18, (here - (len(code) + 2)) & 0xFF) # JR here

rom = bytearray(32 * 1024)
rom[0:len(code)] = code
open(sys.argv[1], "wb").write(rom)
print(f"{sys.argv[1]}: {len(code)} bytes of code in a {len(rom)//1024} kB cartridge")
