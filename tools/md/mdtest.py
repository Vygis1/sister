"""Build a small Mega Drive program that sets the VDP up and draws something.

    python tools/md/mdtest.py sim/roms/md/mdtest.hex

Every console in this tree got one of these before it got a commercial game: a
cartridge whose every pixel is known in advance, so a testbench can check the
picture instead of a person squinting at it. This is the Mega Drive's, and it is
also the first thing that makes the 68000 and the VDP one machine rather than
two modules that each pass their own tests.

What it does, in the order a real game does it:

  - clears VRAM with a fill DMA, because a 68000 writing 32768 words one at a
    time is exactly why the DMA exists
  - sets the registers: both plane bases, the scroll table, H40, display on
  - loads one tile, one name-table entry and two colours
  - takes the Z80's bus, loads a program into its RAM, lets it run, takes the
    bus back and reads what it wrote
  - stops

The result is a solid red cell in the top left corner on a black field, which is
a picture with no ambiguity in it at all, and one byte in VRAM that only gets
there if both processors did their half of the handover.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m68kasm import *                                        # noqa: E402

CTRL  = 0xC00004                # the VDP's control port
DATA  = 0xC00000                # and its data port
STACK = 0x00FFF000

NT_A  = 0xC000                  # plane A's name table, in VRAM
NT_B  = 0xE000
HSCR  = 0xB000


def command(code, addr):
    """The VDP's two-word command, packed into one longword so that a single
    MOVE.L to the control port delivers both halves. That is how real code does
    it, and it is also a check that a long write to a word-wide port lands as
    two consecutive word writes."""
    first  = ((code & 3) << 14) | (addr & 0x3FFF)
    second = ((code >> 2) << 4) | ((addr >> 14) & 7)
    return (first << 16) | second


CD_VRAM_WR  = 0b000001
CD_CRAM_WR  = 0b000011
CD_VSRAM_WR = 0b000101
CD_DMA      = 0b100000          # CD5, which turns a command into a DMA


def build(a):
    a.org = 0
    a.long(STACK)
    a.long(a.at('start'))
    for _ in range(2, 64):
        a.long(a.at('stop'))
    a.pad_to(0x200)

    a.label('start')
    a.lea(AbsL(CTRL), A(0))
    a.lea(AbsL(DATA), A(1))

    def reg(n, v):
        a.move_w(Imm(0x8000 | (n << 8) | v), Ind(0))

    # --- clear VRAM -------------------------------------------------------------
    # Display off while this runs, DMA allowed, and an auto-increment of one so
    # the fill walks bytes rather than skipping every other one.
    reg(1, 0x14)
    reg(15, 1)
    reg(19, 0x00)               # length 0 means 65536: all of it
    reg(20, 0x00)
    reg(23, 0x80)               # mode 10: fill
    a.move_l(Imm(command(CD_VRAM_WR | CD_DMA, 0x0000)), Ind(0))
    a.move_w(Imm(0x0000), Ind(1))
    # No polling: the DMA takes the bus, so the next instruction does not run
    # until it is finished.

    # --- the registers a picture needs ---------------------------------------------
    reg(15, 2)                  # back to whole words
    reg(0,  0x04)
    reg(2,  0x30)               # plane A at $C000
    reg(4,  0x07)               # plane B at $E000
    reg(7,  0x00)               # the backdrop is colour 0
    reg(10, 0x00)
    reg(11, 0x00)               # whole-screen scrolling
    reg(12, 0x81)               # H40
    reg(13, 0x2C)               # the scroll table at $B000
    reg(16, 0x00)               # both planes 32 by 32

    # --- one tile: solid colour 1 --------------------------------------------------
    a.move_l(Imm(command(CD_VRAM_WR, 0x0020)), Ind(0))
    a.moveq(15, D(0))
    a.label('tile')
    a.move_w(Imm(0x1111), Ind(1))
    a.dbra(D(0), 'tile')

    # --- one cell of plane B uses it ------------------------------------------------
    a.move_l(Imm(command(CD_VRAM_WR, NT_B)), Ind(0))
    a.move_w(Imm(0x0001), Ind(1))

    # --- two colours: black, and red ---------------------------------------------------
    a.move_l(Imm(command(CD_CRAM_WR, 0x0000)), Ind(0))
    a.move_w(Imm(0x0000), Ind(1))
    a.move_w(Imm(0x000E), Ind(1))

    # --- and no scrolling ---------------------------------------------------------------
    a.move_l(Imm(command(CD_VRAM_WR, HSCR)), Ind(0))
    a.move_l(Imm(0x00000000), Ind(1))
    a.move_l(Imm(command(CD_VSRAM_WR, 0x0000)), Ind(0))
    a.move_l(Imm(0x00000000), Ind(1))

    # --- the picture is on ---------------------------------------------------------------
    reg(1, 0x54)                # display on, DMA still allowed

    # --- the other computer ------------------------------------------------------------------
    # Take the Z80's bus, hold it in reset, write a program into its RAM, let it
    # go, and then take the bus back and read what it did. That is exactly the
    # dance a real game does to load its sound driver, and it is the only way the
    # two processors ever talk.
    a.move_w(Imm(0x0100), AbsL(0xA11100))       # ask for the bus
    a.label('zwait1')
    a.move_w(AbsL(0xA11100), D(0))
    a.andi_w(0x0100, D(0))
    a.bne('zwait1')                             # bit 8 stays set until it stops
    a.move_w(Imm(0x0000), AbsL(0xA11200))       # and hold it in reset

    #   LD A,$5A / LD ($1000),A / JR -2
    for k, byte in enumerate([0x3E, 0x5A, 0x32, 0x00, 0x10, 0x18, 0xFE]):
        a.move_b(Imm(byte), AbsL(0xA00000 + k))

    a.move_w(Imm(0x0100), AbsL(0xA11200))       # out of reset
    a.move_w(Imm(0x0000), AbsL(0xA11100))       # and give the bus back

    # Long enough for four Z80 instructions, by a wide margin.
    a.move_w(Imm(2000), D(0))
    a.label('zdelay')
    a.dbra(D(0), 'zdelay')

    a.move_w(Imm(0x0100), AbsL(0xA11100))
    a.label('zwait2')
    a.move_w(AbsL(0xA11100), D(0))
    a.andi_w(0x0100, D(0))
    a.bne('zwait2')

    a.moveq(0, D(1))
    a.move_b(AbsL(0xA01000), D(1))              # what the Z80 left behind
    a.move_l(Imm(command(CD_VRAM_WR, 0x5000)), Ind(0))
    a.move_w(D(1), Ind(1))                      # park it where a testbench can see

    # --- the controller port ------------------------------------------------------------------
    # A three-button pad has six buttons and six lines, so it answers with a
    # different half depending on which way TH is driven. A game reads it twice.
    a.move_b(Imm(0x40), AbsL(0xA10009))         # TH is an output
    a.move_b(Imm(0x40), AbsL(0xA10003))         # drive it high
    a.moveq(0, D(2))
    a.move_b(AbsL(0xA10003), D(2))              # C, B and the directions
    a.move_b(Imm(0x00), AbsL(0xA10003))         # drive it low
    a.moveq(0, D(3))
    a.move_b(AbsL(0xA10003), D(3))              # start and A
    a.move_l(Imm(command(CD_VRAM_WR, 0x5002)), Ind(0))
    a.move_w(D(2), Ind(1))
    a.move_w(D(3), Ind(1))

    a.label('stop')
    a.stop(0x2700)
    a.bra('stop')


def cartridge(code):
    """Wrap the program in the header a real cartridge carries.

    The program already looks like one where it matters -- stack pointer at $0,
    entry at $4, sixty-four vectors, code from $200 -- because that is what the
    68000 reads out of a cartridge on reset. What it does not have is the
    identifying block at $100, and nothing inside the console needs it: neither
    the CPU nor the VDP ever looks.

    The HOST looks. A file is recognised as a Mega Drive cartridge by "SEGA" at
    $100 and by nothing else, because unlike a NES ROM there is no other header.
    Without it this image gets handed to the Master System -- which is exactly
    the mistake that made a dropped-in Genesis game show a black screen.
    """
    rom = bytearray(code)
    if len(rom) < 0x200:
        rom.extend(b'\x00' * (0x200 - len(rom)))

    def put(off, data, size):
        rom[off:off + size] = data.ljust(size, b' ')[:size]

    put(0x100, b'SEGA GENESIS    ', 16)
    put(0x110, b'(C)FPGA 2026.SEP', 16)
    put(0x120, b'MDTEST', 48)
    put(0x150, b'MDTEST', 48)
    put(0x180, b'GM 00000000-00', 14)
    put(0x190, b'J', 16)
    rom[0x1A0:0x1A4] = (0).to_bytes(4, 'big')
    rom[0x1A4:0x1A8] = (len(rom) - 1).to_bytes(4, 'big')
    rom[0x1A8:0x1AC] = (0xFF0000).to_bytes(4, 'big')
    rom[0x1AC:0x1B0] = (0xFFFFFF).to_bytes(4, 'big')
    put(0x1F0, b'JUE', 16)

    # The sum of every word from $200 on. Nothing checks it; it is filled in
    # because a cartridge that lies about itself is a poor thing to keep around
    # for testing something else with.
    total = 0
    for i in range(0x200, len(rom) - 1, 2):
        total = (total + int.from_bytes(rom[i:i + 2], 'big')) & 0xFFFF
    rom[0x18E:0x190] = total.to_bytes(2, 'big')
    return bytes(rom)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else 'sim/roms/md/mdtest.hex'
    code = Asm(0).assemble(build)
    os.makedirs(os.path.dirname(out) or '.', exist_ok=True)
    if out.endswith(('.bin', '.gen', '.md')):
        rom = cartridge(code)
        with open(out, 'wb') as f:
            f.write(rom)
        print('%s: %d bytes, a bootable cartridge' % (out, len(rom)))
        return

    with open(out, 'w') as f:
        for i in range(0, len(code), 2):
            f.write('%02x%02x\n' % (code[i], code[i + 1]))
    print('%s: %d bytes' % (out, len(code)))


if __name__ == '__main__':
    main()
