# The shell: one board, several consoles

The idea, in your words: the FPGA flashes itself to become whichever console
you want, so one board is a NES now and a Mega Drive in a minute, and each core
gets the whole chip instead of sharing it.

This is how MiSTer works, and it is the right shape. Here are the numbers that
decide the details, all measured on this board rather than assumed.

## What actually fits

    bitstream, uncompressed      3.65 MB
    bitstream, compressed        1.92 MB     (measured, ~1.9x)
    SPI flash (N25Q064)          8 MB

So the layout is:

    0x000000   shell   2 MB, and it uses half of that
    0x200000   core    6 MB, which is everything else

**ONE core, with the whole chip to itself.** That is the point of the whole
arrangement, and it is worth being blunt about because the obvious alternative
looks attractive and is not. Three 2 MB slots would let three cores sit resident
and switch in milliseconds instead of a minute -- and cost slot allocation,
eviction when a fourth arrives, and a user interface that has to explain which
machine is in which numbered hole. One slot means a core is installed or it is
not.

It also means a core image contains ONE machine. The NES image is a NES; the
Master System image is a different file. Sharing one bitstream between two
consoles is exactly what this replaces, and the numbers say why:

    NES + Master System in one image    9740 LUTs   132.5 / 135 block RAM
    NES alone                           5362 LUTs   125.5 / 135
    Master System alone                 (built the same way)

The block RAM is what matters there. At 132.5 of 135 there was no room for a
third console at all; at 125.5 there is room to grow one.

**Every image in this flash must be compressed, including the shell.** An
uncompressed bitstream for this part is 3.65 MB, which would not fit the shell's
2 MB at all. `BITSTREAM.GENERAL.COMPRESS` is set in tools/build.tcl for that
reason and not as an optimisation.

    shell        995 kB of its 2 MB
    NES core    1866 kB of the slot's 6 MB

The slack in the slot is deliberate: it is where a BIOS image or a cartridge
cache goes when a console wants one.

## How the switching works

Series-7 parts can reconfigure themselves. The sequence is:

1. Write the target address into the warm-boot start register (WBSTAR).
2. Issue IPROG through the ICAPE2 primitive.
3. The FPGA restarts configuration from that address.

Power-up always loads address 0, so **a broken core cannot brick the board** --
pull the power and the shell comes back. That property is why the shell lives at
zero and is never the thing being overwritten.

## Reaching the flash from user logic

After configuration the SPI pins are ordinary I/O, except the clock, which has
to go through the STARTUPE2 primitive. On this package:

    R14   D00_MOSI     data out
    R15   D01_DIN      data in
    P14   D02          (unused in single-bit mode)
    N14   D03          (unused in single-bit mode)
    P18   FCS_B        chip select
    H13   CCLK         via STARTUPE2.USRCCLKO -- not a normal pin

Single-bit SPI is enough: writing 2 MB over a 100 Mbit link is the slow part by
a wide margin, and x4 would complicate the controller for no gain.

## What the 256 MB of DDR3 changes

This was the missing fact, and it changes the answer to two questions.

**The block RAM wall is not a wall.** The cartridge currently costs 96 of the
board's 135 block RAM tiles -- that is the whole reason NES and Master System
together sit at 98%. Moving cartridge storage to DDR3 frees nearly all of it.
256 MB is 683 times the entire current cartridge memory.

**Big cartridges stop being a problem.** A 4 MB Mega Drive ROM does not fit in
block RAM under any arrangement. In DDR3 it is nothing.

The catch is latency. DDR3 answers in tens of cycles with variable timing, and
these cores are written against memory that answers in one or two. So DDR3 holds
the bulk data and block RAM keeps the latency-critical parts -- video memory,
work RAM, line buffers -- with a cache or prefetch between them. That is the
same split every serious core uses, and it is real work, not a wiring job.

## PlayStation: the honest answer

The memory objection is gone. It needs about 4 MB (2 MB main, 1 MB video,
512 kB audio, 512 kB BIOS) and there are 256 MB sitting on the board.

What remains is logic and effort, and that part is not close:

- **The GPU.** A polygon rasteriser with texture mapping, at video memory
  bandwidth. This is the hard part of a PlayStation and it is hard in a way that
  does not shrink.
- **The GTE.** A fixed-point 3D maths coprocessor, about thirty operations,
  most of them multiply-accumulate chains.
- **The CPU.** An R3000A with a pipeline, plus a memory management unit.
- **The SPU.** Twenty-four ADPCM voices with reverb.

The comparable open-source core targets a much larger part with a gigabyte of
DDR3 behind it, and took years. This chip has 63,400 LUTs; the 6502, Z80, two
video chips and two sound chips together currently use 9,777 of them, and that
is the easy end of the problem.

So: **not a realistic target here.** What is reachable, in order:

- **Game Boy / Game Boy Color** -- small, and would fit alongside something else
- **Mega Drive** -- 68000, Z80, VDP, YM2612. Large, well documented, and the
  natural next console. This is the one to aim at.
- **SNES** -- 65816, two picture processors, SPC700 and its DSP. Hard, but has
  been done on parts this size.

## What is built

`rtl/shell_top.v`, and it fits in **4,146 LUTs -- 6.5% of the chip -- with no
block RAM at all**, which is the number that matters: the golden image must
never be the thing that does not fit.

    rtl/esp_link.v      the SPI slave, 10 MHz, three-stage synchroniser
    rtl/spi_flash.v     erase, program and read the configuration flash
    rtl/shell_top.v     the command decode, ICAPE2 and STARTUPE2
    sim/spiflash_model.v  a Micron N25Q that argues back
    sim/tb_spi_flash.v    the writer against that chip
    sim/tb_shell.v        the whole shell, driven over four wires at 10 MHz

Three things that testing found, none of which would have been visible on a
scope and two of which would have been silent:

- **DQ2 and DQ3 are /W and /HOLD in single-bit mode.** The board parks unused
  pins with a pulldown, which asserts write protect and holds the chip. Flash
  writes would have done nothing whatsoever. They are driven high on purpose.
- **Busy has to mean "anything outstanding", not "the flash chip is busy".** A
  slot erase is 32 sector erases, and between them the controller's own flag
  drops for a cycle. A status poll landing in that gap says finished; the ESP32
  starts sending pages; the erase still to come wipes them. A corrupt core and
  nothing anywhere reporting an error.
- **The reply counter must not wrap inside a frame.** A page dump is 258 bytes,
  an eight-bit counter is not.

## Why the board cannot be bricked

Three independent reasons, and this is the part worth being sure about:

1. Power-up configuration always reads address 0. A broken core in a slot is
   one power cycle away from not mattering.
2. The shell cannot overwrite itself. A slot number is two bits and an offset
   is twenty-one, and the flash address is the two CONCATENATED -- so there is
   no offset an ESP32 can send that carries down into the shell. The testbench
   sends $FFFF00 at slot 1 and checks it folds inside slot 1. A comparison
   against slot 0 is there as well, but the arithmetic is what makes it true.
3. `CONFIGFALLBACK` is enabled, so a slot that fails to load returns here
   rather than leaving DONE low, which is indistinguishable from dead.

And JTAG overrides all of it, so even a corrupted flash is recoverable.

## Order of work

1. ~~**The shell**~~ -- done, and verified on the board to the extent it can be
   without an ESP32 on the other end: it configures, DONE goes high.
2. **DDR3** -- the memory controller and a cache layer, then move cartridge
   storage off block RAM.
3. **Mega Drive** -- which needs both of the above to be comfortable.
