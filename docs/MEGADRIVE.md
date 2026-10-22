# Mega Drive

How the Mega Drive core is built and how it is checked.

## The machine

    68000          7.67 MHz    the main CPU                         rtl/m68k.v
    Z80            3.58 MHz    the sound CPU                        rtl/z80.v, rtl/md_sound.v
    VDP 315-5313   13.4 MHz    two planes, a window, 80 sprites     rtl/md_vdp.v
    YM2612                     six-channel FM                       rtl/ym2612.v
    SN76489                    the Master System's sound chip       rtl/psg.v
    work RAM       64 kB       the 68000's                          block RAM
    Z80 RAM         8 kB                                            block RAM
    VRAM           64 kB       the VDP's own                        block RAM
    cartridge      up to 4 MB                                       DDR3, through rtl/cart_cache.v

`rtl/md_top.v` is the machine: the chips and the memory map between them.

    $000000-$3FFFFF   cartridge
    $A00000-$A0FFFF   the Z80's space, through a window
    $A10000-$A1001F   controllers and the version register
    $A11100           Z80 bus request
    $A11200           Z80 reset
    $C00000-$C00007   the VDP: data at 0 and 2, control at 4 and 6
    $C00008           the H/V counter
    $FF0000-$FFFFFF   work RAM

`rtl/md_console.v` adapts it to the rest of the project: the clock enables, and the colour
conversion for the picture.

## Clocks

Every part of a Mega Drive runs from its 53.693175 MHz master clock divided by an integer: 7 for
the 68000, 4 for the VDP in H40, 15 for the Z80, 7 x 144 for the FM chip. `md_console.v` makes
those four enables from its own clock with the same divisors. The ratios between the chips are
therefore always the console's. The absolute speed is the image's clock divided by 53.693 MHz.

A cartridge read can take tens of clocks. Nothing in the machine handles that as a special case:
the 68000 does not get its clock enable until the answer is there, and the VDP's DMA and the
Z80's window wait on the same signal.

## The cartridge

The cartridge lives in DDR3 (`rtl/cart_ddr3.v`) behind `rtl/cart_cache.v`. The cache is
direct-mapped, with a line of eight 16-bit words to match a DDR3 burst. It issues a prefetch
halfway through each line, not at its end, so the next line is usually there before it is
needed. One request is outstanding at a time and hits are served while it is in flight. It has
two requesters: the 68000 (which the VDP's DMA also goes through) and the Z80's window.

`sim/tb_cart_cache.v` measures it against a DDR3 model that answers in 12 clocks on an open row
and 30 on a closed one, with a 68000's gap between reads:

    streaming 4096 words in order     4095 hits, 1 miss, 512 lines prefetched, 1 clock of waiting per read
    256 reads scattered               0 hits, 256 misses, 34 clocks of waiting per read

A 68000 bus cycle is four of its clocks, 28 of the fabric's, so a streaming read costs about
one clock in 28.

`rtl/md_cart.v` answers the same line interface out of block RAM. It is used only when the core
is built without DDR3 (`MD_DDR3=0`), for test ROMs.

## The 68000 — `rtl/m68k.v`

All twelve addressing modes through one effective-address resolver. A memory access goes to a
shared state, and a continuation code says where to resume, so an instruction half way through
is never decoded again (the same structure as the Z80, see [Z80-DESIGN.md](Z80-DESIGN.md)).

Implemented: MOVE, MOVEA, MOVEQ, MOVEM, LEA, PEA, EXG, SWAP, EXT, LINK, UNLK; ADD, SUB, AND,
OR, EOR, CMP and their immediate, quick, address and extended forms, CMPM; CLR, NEG, NOT, TST,
TAS and the four bit instructions; MULU, MULS, DIVU, DIVS with the divide-by-zero exception;
every shift and rotate on a data register; BRA, BSR, Bcc, DBcc, Scc, JMP, JSR, RTS, RTE;
autovectored interrupts, TRAP, ILLEGAL, lines A and F, STOP, and MOVE to and from SR and CCR.

Not implemented (listed in the file's header): MOVEP, the one-bit memory shifts, MOVE USP, CHK
and TRAPV, the BCD instructions, address and bus errors, tracing, and a separate user stack
pointer. An opcode the decoder does not know raises vector 4 and latches the opcode and PC, so
a missing instruction is reported where it happens.

The bus is not the real chip's /AS, /UDS, /LDS, /DTACK handshake: it is 16 bits wide with one
enable of latency, like the other cores here.

## The VDP — `rtl/md_vdp.v`

- The control port's two-word command, the register file, VRAM, CRAM and VSRAM with
  auto-increment. A status read abandons a half-written command.
- Video timing for H40 and H32.
- Both scrolling planes with flips, palettes, priority, and horizontal and vertical scrolling
  (whole screen, per cell or per line), and the window layer.
- The vertical-blank and line interrupts, and the H/V counter at $C00008.
- All three DMA kinds: from the 68000's memory, VRAM fill, and VRAM to VRAM.
- Sprites: the linked list, column-major tiles, flips and priority against both planes. A
  sprite attribute cache keeps each entry's Y, size and link inside the chip, as the real one
  does, so walking the list costs no VRAM reads. The sprite engine fills a line buffer during the line
  before the one it appears on. It reads VRAM only in the slots the plane fetch leaves free (two
  in every eight while the picture is drawn, nearly all of them in blanking): it asks for a slot
  and waits. When it runs out of line it stops and sets the overflow flag, as the real chip
  does.

Not done: the interlaced modes and shadow/highlight.

## Sound — `rtl/md_sound.v`, `rtl/ym2612.v`

`md_sound.v` is the Z80 and what surrounds it:

    $0000-$1FFF   its RAM, mirrored at $2000
    $4000-$4003   the YM2612
    $6000         the bank register
    $7F11         the SN76489
    $8000-$FFFF   a 32 kB window into the 68000's memory

The 68000 stops the Z80 and takes its RAM through $A11100 (bus request) and $A11200 (reset).
That is how a game loads its sound driver and passes it commands. The Z80 gets the VDP's
vertical-blank interrupt. The bank register is a shift register: nine writes of one bit each,
least significant first, choose which 32 kB the window shows.

The YM2612 computes its arithmetic in decibels, as the real chip does. A sine lookup returns an
attenuation, the envelope is an attenuation, and applying one to the other is an add. The
result is turned back into a linear value once, at the end, through an exponential table. Both
tables are in `rtl/ym_tables.vh`, generated from their definitions by `tools/md/ymtables.py`.

All 24 operators share one datapath, four clocks each, in turn. The FM sample enable must
therefore be at least 96 clocks apart; a faster one restarts the pass before it finishes and the
chip goes silent.

The register interface: two address/data pairs, channels 1-3 through the first and 4-6 through
the second; operators appear in the register map in the order 1, 3, 2, 4, as on the chip; the
two timers count up to an overflow.

Not exact, as the file's header lists: the envelope's rate steps are not checked against real
hardware; operators are computed in the order 1, 2, 3, 4 (the chip uses 1, 3, 2, 4 with a
one-sample delay on some paths); detune and the LFO are not implemented.

## The picture

The VDP's 9-bit colour goes to HDMI through `rtl/frame_hdmi.v`, 256 or 320 x 224, doubled.

## A rule for memories

Block RAM has two ports. A memory written from more than one place, with nothing in the Verilog
saying the writes never collide, is built by Vivado out of LUTs or flip-flops, with no warning.
In this core that once turned the 64 kB of VRAM into about 20,000 LUTs, and the sprite line
buffers into 8,000 flip-flops. The rule: **one write port per array, with its address and data
muxed explicitly, and a synthesis run before the module is trusted.** A passing simulation says
nothing about whether a design fits.

## Tests

| Bench | What it checks |
|---|---|
| `sim/tb_m68k.v` | hand-written programs, one instruction group at a time |
| `sim/tb_m68krom.v` | a program generated by `tools/md/m68ktest.py`: operand sweeps against a Python model of the 68000, flags checked apart from results; it stops at the first disagreement, and `sim/roms/m68k/m68ktest.txt` names each case |
| `sim/tb_md_vdp.v` | the VDP |
| `sim/tb_ym2612.v` | the FM chip's ports, timers, key-on, DAC and operators |
| `sim/tb_cart_cache.v` | the cartridge cache (the measurement above) |
| `sim/tb_md_cart.v` | the block-RAM cartridge's line interface and byte order |
| `sim/tb_md_top.v` | the whole machine running a program built by `tools/md/mdtest.py` |
| `sim/tb_md_console.v` | the clock enables and the colour conversion |
| `sim/tb_md_hw.v` | the console as the board wires it, filled over the register bus |
| `sim/tb_md_game.v` | a real cartridge: undecoded opcodes, DMA correctness, deadlocks, interrupts |
| `sim/tb_md_z80trace.v` | how a game hands its sound driver to the Z80 |

`tools/md/m68kasm.py` is the assembler the test programs are built with. It checks itself
against encodings worked out by hand (`python tools/md/m68kasm.py`).
