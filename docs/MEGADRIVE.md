# The Mega Drive: what it takes

The next console, and the first one that does not fit the pattern of the other
two. Worth writing down before any of it is built, because one of the pieces
below is a dependency that cannot be worked around and it is better known now
than discovered three weeks in.

## What the machine is

    68000          7.67 MHz    the main CPU
    Z80            3.58 MHz    runs the sound, and can be used as a co-processor
    VDP 315-5313   13.4 MHz    two scrolling planes, sprites, 64 kB of its own RAM
    YM2612                     six-channel FM synthesiser
    SN76489                    the Master System's sound chip, still here
    work RAM       64 kB       the 68000's
    Z80 RAM         8 kB
    VRAM           64 kB       the VDP's, not shared with anything

Two of those already exist in this tree. The Z80 passes ZEXDOC and ZEXALL on
hardware, and the SN76489 has been playing Master System music for a week. That
is not nothing: it is two of the five chips, and the two that are easiest to get
subtly wrong.

## The dependency: this one needs DDR3

Every console so far has kept its cartridge in block RAM. A Mega Drive cannot,
and the arithmetic is not close:

    block RAM on this chip          4860 Kb   =  607 kB
    Mega Drive work RAM               512 Kb
    VDP VRAM                          512 Kb
    Z80 RAM                            64 Kb
    framebuffer (256x240, RGB332)     480 Kb
                                    --------
    left for a cartridge             3292 Kb  =  411 kB

A small Mega Drive cartridge is 512 kB. Sonic 1 is 512 kB. Streets of Rage 2 is
2 MB. Even the smallest common game does not fit in what is left, and that is
before the margin every one of these cores has needed.

So **DDR3 comes first**. Not as a nice-to-have that makes things comfortable, as
it would for the NES -- as the thing without which there is no Mega Drive at
all. 256 MB sits on the board unused.

The catch is the one already written down in SHELL.md: DDR3 answers in tens of
cycles with variable timing, and a cartridge read has to look like ROM. That
means a cache between them. Cartridge reads are the friendly case for one --
code runs forwards, and the VDP's tile fetches walk memory in order -- so a
modest cache with a prefetch should hide nearly all of it. "Should" was doing
the work in that sentence, which is why the first DDR3 milestone was a
measurement and not a feature. It has been taken; the next section has it.

## The measurement that had to come first -- and its answer

The plan below said the first DDR3 milestone should be a NUMBER, not a feature:
if a cached sequential read is not comfortably inside a 68000 bus cycle, the
Mega Drive needs a different shape, and it is better to know that before the VDP
is written around the assumption.

The number is in. `rtl/cart_cache.v` is a direct-mapped cache, eight words to a
line to match a DDR3 burst, with a prefetch issued halfway through each line
rather than at the end of it. `sim/tb_cart_cache.v` drives it through a DDR3
model whose latency depends on whether the row is already open -- 12 cycles if
it is, 30 if it is not -- with a gap between reads of about what a 68000 takes
to get from one instruction fetch to the next.

    streaming 4096 words in order
      4095 hits, 1 miss, 512 lines prefetched before they were asked for
      1 cycle of waiting per read

    256 reads scattered across the cartridge
      0 hits, 256 misses
      34 cycles of waiting per read

A 68000 read at 7.67 MHz is about 28 clocks of a 50 MHz fabric. So a streaming
read -- which is what instruction fetch is, and what a VDP DMA is by definition
-- costs one clock out of twenty-eight. Even the pathological case, every read a
miss in a different DDR3 row, costs about one extra bus cycle.

**DDR3 behind this cache looks like a cartridge.** The Mega Drive does not need
a different shape.

What is not answered, and cannot be until the board has power again: whether the
real controller's latency matches the model's. The model is pessimistic on
purpose -- 30 cycles for a row miss is worse than a MIG at 4:1 usually manages --
but pessimistic is not the same as right.

The cache costs 544 LUTs and three block RAM tiles.

## Order of work

1. ~~**DDR3 controller and cache.**~~ The cache is built and measured; see
   above. What is left is the MIG itself, which needs the board's DDR3 pinout
   and a powered board to verify against.
2. **68000.** The largest single module in this project by a wide margin, and
   the one that must be exactly right. Entirely testable in simulation, and
   independent of everything above -- so it can be built in parallel with the
   memory work rather than after it.
3. **VDP 315-5313.** Related to the Master System's VDP but bigger: two scroll
   planes instead of one, a window layer, 80 sprites, and its own 64 kB.
4. **YM2612.** Six FM channels, four operators each. Well documented, and the
   part that makes a Mega Drive sound like one.
5. **Bus arbitration.** The 68000 and the Z80 share the cartridge and can stall
   each other. This is where two working CPUs become one working machine, and
   it is the part that will be wrong first.

## Where the 68000 stands

Built, and passing 126 hand-written checks in `sim/tb_m68k.v` plus 2472
generated ones in `sim/tb_m68krom.v`. Out-of-context synthesis for
the xc7a100t puts it at **5688 LUTs, 1090 flip-flops, one DSP slice and no block
RAM** -- at the low end of the 6-9k estimated below, and cheaper than the NES
core it sits beside.

What is implemented, and tested:

- All twelve addressing modes, including d8(An,Xn) and both PC-relative forms.
- MOVE, MOVEA, MOVEQ, MOVEM, LEA, PEA, EXG, SWAP, EXT, LINK, UNLK.
- ADD, SUB, AND, OR, EOR, CMP in both directions, the immediate forms, ADDQ and
  SUBQ, ADDA/SUBA/CMPA, ADDX/SUBX/NEGX, CMPM.
- CLR, NEG, NOT, TST, TAS, and all four bit instructions in both forms.
- MULU, MULS, DIVU, DIVS, with the divide-by-zero exception.
- Every shift and rotate on a data register, including ROXL/ROXR through X.
- BRA, BSR, all fourteen Bcc, DBcc, Scc, JMP, JSR, RTS, RTE.
- Autovectored interrupts, TRAP, ILLEGAL, lines A and F, STOP that actually
  waits, and MOVE to and from SR and CCR.

What is not, and is known to be missing: MOVEP, the one-bit memory shifts, MOVE
USP, CHK and TRAPV, the BCD instructions, address and bus errors, tracing, and a
separate user stack pointer. None of those is needed to run a boot ROM; each
gets its tests when it arrives.

**An unknown opcode now raises vector 4.** It used to do nothing at all --
three separate `default: ;` arms, one per level of the decoder. That is the
worst answer available: the program runs on past a missing instruction, drifts
for thousands of cycles and dies somewhere unrelated, so a missing opcode looks
exactly like a broken VDP or a broken memory controller. Those get suspected
first, because they are what changed most recently.

## The one that stopped every commercial game

`LEA $00FFF000,A7` was executed as `JMP $00FFF000`.

LEA and JMP share a state, because both want the address out of the effective
address unit and not what is at it. They are told apart on entry to it, and the
test read:

    if (ir[15:12] == 4'b0100 && ir[8:6] == 3'b111 && ir[11:9] != 3'b111)

The last clause was there to keep JMP out. JMP is `0100 1110 11 mmmrrr`, so its
`ir[11:9]` is 111 -- but so is LEA's when the destination register is **A7**,
and A7 is the stack pointer. The clause excluded the stack pointer from being a
valid LEA destination and sent it down the JMP path instead.

It was also unnecessary. JMP's `ir[8:6]` is `011`; LEA's is `111`. The test
before it already separated them.

Setting up a stack is the first thing a cartridge does. Combat Cars does it at
$06c2, three instructions in, and jumped to $00FFF000 -- into the stack it was
in the middle of establishing -- before touching the VDP. Every commercial game
dies the same way, which is why the black screen looked like a video problem.

The hand-written test cartridge never caught it because it kept the stack
pointer the reset vector gave it and never loaded A7 itself. The test that would
have caught it is one line: `LEA` to each of the eight address registers, A7
included.

Found with `sim/tb_md_game.v`, which runs a real cartridge and reports the PC
history when control flow leaves the ROM -- the trace showed $06be, $06c0 ...
$06c8, $FFF000, and the ROM at $06c2 said LEA.

With it fixed, Combat Cars boots: it clears work RAM from $FF0288 to $FFCB10 a
word at a time, writes all 64 CRAM entries, fills 25602 words of VRAM, and draws
its character select screen -- eight portraits and their names, sixteen colours,
in `build/md_sim_frame.png`. The same testbench captures the frame, so the next
cartridge that fails can be looked at rather than guessed about.

## The car that was not there

With the CPU fixed the game ran, and every sprite was invisible. The engine was
fine: 1.7M fetch cycles, 400k sprite tests, 5568 pixel cycles all on-screen --
and zero writes to the line buffer, because every pattern word it fetched came
from VRAM the game had never written. The tile index was wrong before the
engine ever saw it.

The sprite table travels RAM to VRAM by DMA every frame, and that path was
handing over the PREVIOUS word: Y arrived as size, size as attribute. The
cartridge holds its answer through a handshake, so one clock of waiting is
exact; work RAM is a registered read, `wram_q` is `wram[bus_a]` as of the
clock before, and one clock of waiting takes the word before the one asked
for. Checked the same way the cartridge path had been -- every DMA word
against the memory it came from -- 3236 of 21888 were wrong. The cartridge
path being clean is exactly why it hid.

RAM sources now wait a second clock (`md_top.v`, the DMA phase counter). After:
0 wrong of 21888, 171568 sprite pixels on screen, decoded entries that read as
a linked list of 2x2 sprites on palette 3 -- the car.

Confirmed on the board: Combat Cars on its start grid with five cars lined up
under READY, captured straight off the framebuffer. `cores/md.bit` is that
build.

Also fixed on the way, each found by a measurement rather than a theory:

* `LEA` to A7 executed as `JMP` (above).
* A cached cartridge answer for the wrong address wedged the bus for good.
* `$C00008` aliased onto the data port, so the H/V counter did not exist;
  games that poll it for the top of the frame span forever. It exists now,
  with the counters' jumps, because a game waiting for line $D0 was woken six
  lines early without them and did its VDP work with the raster in the wrong
  place.
* The framebuffer was 256 wide and the clamp in console_top dropped everything
  past it, so H40 games lost their right quarter.

`sim/tb_md_game.v` now runs a real cartridge and reports: undecoded opcodes,
DMA correctness on both paths, deadlocks with the bus state, interrupt
accounting, and how far the sprite engine gets. Start there.

The flags are the part that took the work, and the tests reflect that: X, N, Z,
V and C are checked separately from the results, so an instruction that produces
the right number with the wrong flags still fails. Real bugs caught that way: a
signed multiply that Verilog's signedness rules had quietly turned unsigned, a
DBcc that has to run n+1 times and end at -1, an extension-word fetch one cycle
short which made STOP load its own opcode into the status register, an ADDQ that
could not reach a memory destination, and a divide that forgot to clear the carry
when it overflowed.

## Where the VDP stands

Built, and passing 72 checks in `sim/tb_md_vdp.v`. **1426 LUTs, 1088
flip-flops and 16 block RAM tiles** -- the tiles being the 64 kB of VRAM, which
is all of them, and 274 of the LUTs being the sprite line buffers.

Done and tested: the control port with its two-word command, the register file,
VRAM, CRAM and VSRAM with auto-increment, the status read that abandons a
half-written command, video timing for H40 and H32, both scrolling planes with
flips, palettes, priority and fine horizontal and vertical scrolling, the VBlank
and line interrupts with their counter, all three kinds of DMA -- from the
68000's memory, VRAM fill, and VRAM to VRAM -- and sprites, with their linked
list, their column-major tiles, their flips and their priority against both
planes, and the window layer.

The video path is complete. What is left of the VDP is the things a game notices
only when it is doing something clever: the H/V counter a light gun reads, the
interlaced modes, and the shadow and highlight bits.

The sprite layer is worth a note, because it is the part whose shape was decided
by what would FIT rather than by what the manual says. Sprites are fetched into
a line buffer during the line before the one they appear on, and the fetches can
only use the VRAM slots the plane fetch leaves free -- two in every eight while
the picture is drawn, and nearly all of them during the blanking. So the engine
asks for a slot and waits, rather than reading whenever it likes, and when it
runs out of line it stops and sets the overflow flag. That is what the real part
does too, and it is why a Mega Drive game flickers its sprites when it asks for
too many.

## The other computer

`rtl/md_sound.v` is the Z80 and everything around it: its eight kilobytes, the
SN76489 the Master System core already drives, the bank register, and the window
through which a sound driver reads its music out of the cartridge. The Z80
itself is the one that already passes ZEXDOC and ZEXALL on hardware.

The part worth testing is not the Z80, it is the handover. `tools/md/mdtest.py`
does the whole dance a real game does to load its sound driver: ask for the bus
at $A11100 and spin until bit 8 clears, hold the Z80 in reset at $A11200, write
a program into its RAM a byte at a time, let it out of reset, give the bus back,
wait, take the bus again and read what the Z80 left behind. The testbench checks
the byte that comes out the far end -- which only appears if both processors did
their half.

The bank register is a shift register: nine writes, one bit each, least
significant first. A driver that sets it with a single write gets whatever one
bit it happened to send, and the classic symptom is music that plays from the
wrong 32 kB.

`rtl/ym2612.v` is the FM chip, and it makes a sound. Both register ports, the
register file, the timers, key-on, the DAC, and the operators -- phase
generator, envelope generator, feedback and all eight algorithms -- passing 33
checks in `sim/tb_ym2612.v`.

The one thing to understand about this chip is that its arithmetic is in
DECIBELS. A sine lookup does not return a sine, it returns how far down from
full scale that point of a sine is; the envelope is also an attenuation. So
applying an envelope to an oscillator is an add, and the only conversion back to
a linear number happens once, at the very end, through an exponential table.
Both tables are generated from their mathematical definitions by
`tools/md/ymtables.py` rather than transcribed, because a table one entry out
sounds almost right and cannot be eyeballed.

Twenty-four operators share one datapath, four clocks each -- the same
arrangement `rtl/synth.v` uses for its eight voices. That makes the sample
enable a REQUIREMENT rather than a preference: it has to be at least 96 clocks
apart, and one that arrives sooner restarts the pass before it finishes, leaving
the chip silent without complaining about anything. That is written into the
module header, because it cost an hour to find.

What is not verified is written down in the file rather than left to be
discovered: the envelope's exact rate steps, the operator ordering (1,2,3,4 here
against the real chip's 1,3,2,4 with a delay on some paths), and detune and the
LFO, which are not implemented. Each is audible to somebody who knows the tune;
none stops a driver from working. Settling them needs a recording from real
hardware, which needs a powered board.

The register interface is more of the chip than it looks. Four addresses in two
pairs, with channels 4 to 6 reached only through the second pair -- so the
documented register map describes three channels and there are two copies of it.
Operators appear in that map in the order 1, 3, 2, 4, which is not an error in
anybody's notes; the silicon is laid out that way. A channel field of 3
addresses nothing. And the two timers count UP to an overflow, so what a driver
writes is the period subtracted from the top. Every one of those is a way for a
register to land somewhere plausible and wrong, and each has a check.

Both processors can reach it: the Z80 at $4000 in its own space, the 68000
through the same addresses in its window. Games use whichever is convenient.

## It is a machine now

`rtl/md_top.v` wires the two together with the memory map between them, and
`sim/tb_md_top.v` runs a real program through it: a cartridge at address zero
that clears all 64 kB of VRAM with a fill DMA, sets the registers a game sets in
its first hundred instructions, loads a tile and a colour, and draws. The
testbench checks the pixels that come out.

That is the first thing in this project that is a Mega Drive rather than a
collection of parts, and it exercises the joins rather than the pieces: a DMA
taking the bus from the processor and giving it back, a MOVE.L to a word-wide
port arriving as two consecutive word writes, an interrupt acknowledge crossing
from one module to the other, and two clock enables at different rates -- 
deliberately not the same rate, because a design that only works when both sides
tick together works in exactly one testbench.

The program is built by `tools/md/mdtest.py` out of the same assembler the 68000's
own tests use.

The cartridge in that test is not a ROM. It is `cart_cache` in front of a memory
that takes twenty-four cycles to answer, which means the whole machine has to
cope with a cartridge that stalls -- and the way it copes is that nothing
"handles" it at all. The 68000 simply does not get a clock enable until the
answer is there, the VDP's DMA waits for the same signal, and the Z80's window
does too. No retries, no wait states, no state machine anywhere that has to know
a read might not finish this cycle. That is the same mechanism a DMA already
uses to take the bus off the processor, used twice.

## Getting it onto the board

`rtl/md_console.v` is the adapter between the machine and this project: the four
clock enables, and the conversion from the VDP's colours to the framebuffer's.
Everything specific to the BOARD lives there, so `md_top.v` stays a description
of a Mega Drive rather than of the thing it happens to be running on.

It wants **53.693 MHz**, not the board's 50, and expects an MMCM in front of it.
That is not fussiness: every part of a Mega Drive is the master clock divided by
an integer -- 7 for the 68000, 4 for the VDP, 15 for the Z80, 7 x 144 for the FM
chip -- and those integers only come out right from 53.693. Running the whole
thing at 50 keeps every ratio between the chips correct, which sounds harmless,
and means the music plays seven per cent flat and the frame rate is 56 Hz.

The framebuffer is the same `rtl/video.v` the other two consoles use, with W and
H set to 320 and 224 instead of 256 and 240. That is 17920 words rather than
15360, so about eighteen block RAM tiles instead of fifteen.

A whole Mega Drive bitstream therefore lands at roughly **14000 LUTs and 56
block RAM tiles** of 63400 and 135, once the framebuffer, the Ethernet
infrastructure and the DDR3 controller are added to the figures below.

### What it costs so far

    68000             5725 LUTs   1073 FFs    0 BRAM   1 DSP
    VDP               1486        1089       16
    Z80 + sound       3585        2642        2        1
      of which YM2612 1569        2189        -        1
    cartridge cache    498         356        3
    work RAM (64 kB)     -           -       16
    ---------------------------------------------------
    md_top           11294 LUTs   5328 FFs   38 BRAM   2 DSP

Against 63400 LUTs and 135 block RAM tiles: **eighteen per cent of the logic and
twenty-eight per cent of the memory**, with the framebuffer and the DDR3
controller still to add. There is room, and there always was -- the cartridge was
the only thing that did not fit, and DDR3 with the cache measured above is the
answer to it.

Three things went wrong while building it, all of them the same KIND of thing --
something that worked in the easy case and only broke at an edge:

- The VRAM read register was not gated by the pixel enable, so it answered on
  every clock while the fetch schedule counted in pixel slots. The data turned
  up a slot early and every capture took the previous fetch's answer. Solid
  tiles still looked right, which is why the first test drawn was a diagonal.
- A line is 420 cycles in H40 and 342 in H32, and neither is a multiple of
  eight, so the fetch groups do not line up with the line boundary. The leftmost
  cell of every line came out as whatever the right-hand edge had left behind.
- The cell being fetched was recomputed from the live counter in every slot
  rather than latched once per group. With no scrolling the two are identical;
  with a scroll of three, the name entry and the pattern came from two different
  cells.

## The 64 kB that nearly cost 16000 LUTs

VRAM is block RAM, and block RAM has exactly two ports. The first version
reached it from three places -- the CPU's write, the CPU's read, and the
renderer's -- and Vivado quietly built the whole 64 kB out of distributed
memory: **19915 LUTs and 16402 LUTRAMs**, a quarter of the chip, for something
that should cost sixteen tiles and no logic at all.

Nothing failed. Simulation passed, no warning was issued, and the only sign was
a utilisation report nobody had run yet. Folding the CPU's read and write into
one always block and leaving the renderer the other port brought it to 669 LUTs
and 16 tiles.

It happened a second time, in a different disguise. The sprite line buffers are
written from two places -- cleared as the line is read out, filled as the next
line is prepared -- and although those two can never touch the same array in the
same cycle, nothing in the Verilog said so. Vivado built both buffers out of
flip-flops: **the VDP went from 871 LUTs to 16242, and from 937 flip-flops to
8348**, for 7168 bits of memory. Muxing the address and data down to one write
port each brought it back to 1367 LUTs, 274 of them distributed RAM.

The rule this leaves behind, for the Mega Drive work RAM and for everything
after it: **a memory gets ONE write port per array, with its address and data
muxed explicitly, and synthesis is run before the module is believed.** A
simulation that passes says nothing at all about whether the thing will fit, and
neither version of this mistake produced a warning.

## The two kinds of test, and why there are two

`sim/tb_m68k.v` is fourteen programs written as hex words by hand. That is the
right shape for a new instruction group: the first test of anything is written
while the thing is being written, and it is worth being able to see exactly what
the processor is being asked to do.

`sim/tb_m68krom.v` is the other half, and it is where the coverage actually
comes from. `tools/md/m68ktest.py` holds a model of the 68000's arithmetic written
in Python from the manual, and generates a program that sweeps operand pairs
against it -- every combination of signs, both directions of carry and borrow,
the values where adding one flips the sign, shift counts of 0 and 68 as well as
1 and 8. Two independent descriptions of the same rules. Where they disagree,
the program stops and records the case number, what the processor produced and
what the model expected; `sim/roms/m68k/m68ktest.txt` says what that case number
was.

The programs are built by `tools/md/m68kasm.py`, a small assembler in the same
shape as `tools/sms/smstest.py` -- Python calls rather than text to parse, so the
thing that writes the test is in the same language as the thing that checks it.
It verifies itself against 93 encodings worked out by hand (`python
tools/md/m68kasm.py`), which is what stops "the assembler and the CPU agree"
meaning "they are wrong together".

Both sweeps were checked against deliberate damage before being believed: an
error injected into the Python model, and separately a fix removed from the
Verilog, each caught at the right case with the right values. A generated test
that passes the first time is worth exactly nothing until it has been seen to
fail.

## How the 68000 gets verified

The same way the 6502 and the Z80 did, because it is the only approach that has
worked here: a reference that disagrees loudly.

- **A self-checking test program**, assembled by a tool in this tree the way
  `tools/sms/smstest.py` and `tools/nes/uxtest.py` already do. Every instruction form
  computes something whose answer is known, and writes a byte saying so.
- **Condition codes checked separately from results.** Half of what goes wrong
  in a 68000 is X, N, Z, V and C after an operation that produced the right
  number. A test that only checks the number passes anyway.
- **Addressing modes as their own axis.** Twelve of them, and a bug in one shows
  up as a handful of unrelated instructions failing.

The instruction set is large enough that "write it all and then test it" is not
a plan. Each group gets its tests as it is written.

## What it should cost

Estimated from what is already measured in this tree -- the NES core alone is
2641 LUTs on top of 2721 of shared infrastructure:

    68000          6-9k LUTs
    VDP            4-6k
    YM2612         4-6k    (DSP slices carry the multiplies; 240 available)
    Z80            2.5k    already built
    SN76489        0.3k    already built
    infrastructure 2.7k
                  --------
                  ~20-27k of 63,400

Comfortable, and it is comfortable *because* each core now gets the whole chip
to itself. Sharing one bitstream between the NES and the Master System cost 132
of 135 block RAM tiles and left no room for anything; one machine per image is
what makes a third console possible at all.
