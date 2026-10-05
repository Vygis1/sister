# Roadmap: from "an FPGA that runs NES games" to "a console"

Where this stands today, and the order the remaining work should happen in.
Each step is written so it can be finished and verified on its own -- nothing
here needs a later step to be useful.

## Done

- fpgalink: a register bus over UDP, no CPU in the path
- Logic analyser, synth, framebuffer + video streaming
- 6502: passes Klaus Dormann's functional test and matches the nestest golden
  log for all 8991 logged instructions
- 2C02 PPU: background, sprites, sprite 0 hit, correct frame geometry
- Cartridge: NROM (mapper 0) and MMC3 (mapper 4), the latter including the
  A12 scanline counter that drives split-screen effects
- Super Mario Bros and Super Mario Bros 3 both run

## The constraint that shapes everything below

The XC7A100T has 135 block RAM tiles, about 600 kB. The framebuffer, audio ring
buffer, analyser buffer and NES cartridge already account for most of it. A
second console cannot have its own cartridge memory on top of the first one's.

So: **one cartridge memory, shared, sized for the largest cartridge any console
supports.** Only one console runs at a time, which is also true of real
hardware. This is the decision that makes multi-console possible at all, and it
has to be made before the second console is started, not after.

---

## Progress

- Step 1 (block RAM) **done**, partly walked back: the synth ring buffer was cut
  too far and audio needed the margin returned. 93% of block RAM in use.
- Step 2 (console interface) **done**: `console_top.v`, `cart_mem.v`, a
  `CONSOLE` register carrying both the selected core and which cores the
  bitstream actually contains.
- Step 3 (web UI) **done**: `web/console.js`, gamepad, drag-and-drop, rebinding.
- Step 4 (APU) **done**: five channels, the non-linear mixer as build-time
  tables, a DC blocker. Verified tonal on hardware.
- Step 5 (Master System) **done**. A whole machine runs on the board: Z80
  (ZEXDOC and ZEXALL both 67/67 on hardware), VDP with background and sprites,
  the Sega mapper, 8 kB of work RAM, and the SN76489. Verified on hardware by
  capturing a frame and analysing the audio -- all three tone channels appear
  at exactly the frequencies the cartridge programmed.

  Both consoles share one cartridge slot and one bitstream. Which machine runs
  is decided by the file: an iNES header is self-announcing, anything else is a
  Master System ROM.

  Resource note: block RAM is at **98%**. The VDP's VRAM was halved from eight
  tiles to four by sharing one read port between the renderer and the CPU --
  which is also what the real chip does, and why games load tiles during
  blanking. There is no room left for a third console without finding more.

- Step 5b (**real Master System cartridges**) **done**. The hand-written test
  cartridge ran; commercial games showed a black screen, which turned out to be
  two separate faults that the test cartridge could not have found.

  **Every `IN` on the machine read memory instead of the port.** The Z80 pulses
  its I/O strobe for one enable cycle and samples the bus on the next, the same
  way it reads memory -- but the data mux was gated on the strobe, which by then
  had dropped. Ports answered writes perfectly and reads not at all. The one
  thing every game does with that is ask the VDP "was that interrupt the
  VBlank?", get no for an answer forever, and never draw. The test cartridge
  read the status port and threw the byte away, so it acknowledged correctly and
  noticed nothing. It now branches on the answer, watches the V counter move,
  and checks the control pad reports exactly what is held -- six checks that all
  fail on the old code.

  **The first tile of every line came out of an unprimed pipeline.** The
  background fetch runs two tiles ahead and had nowhere to start them: sprite
  fetching filled all 86 cycles of horizontal blanking. The line was not short
  of bandwidth -- 316 reads needed out of 342 -- it was short of schedule,
  because a fifth of the sprite fetch was spent waiting for a tile number so the
  address depending on it could be formed. Hoisting that dependency out of the
  loop (all sixteen X-and-tile bytes first, then all thirty-two plane bytes,
  neither pass ever stalling) cut 80 cycles to 52 and left 34 for priming.

  Snail Maze, Alex Kidd in Miracle World and Sonic the Hedgehog all render their
  title screens in simulation, the last of them through the Sega mapper.

## Step 1 -- A console interface, and the NES moved behind it

Before adding a second machine, give the first one a boundary.

Define what a console *is* to the rest of the design:

    input   clk, rst, ce
    input   [7:0] joy1, joy2
    output  [8:0] px, py          pixel position
    output        pixel_en
    output  [7:0] rgb             already resolved to RGB332
    output        frame_start
    output  [N:0] rom_addr        into the shared cartridge memory
    input   [7:0] rom_data

Then wrap the NES in it, and add a `console_sel` register. Nothing changes
behaviourally; the point is that step 4 becomes an addition rather than a
rewrite. Verify by re-running the existing ROM suite.

## Step 2 -- The web UI, rebuilt around the console

The current page is a debugger with a NES tab bolted on. Invert that.

- The screen is the page: large, pixel-crisp, correct 8:7 aspect, fullscreen
- A cartridge slot: drag a ROM anywhere on the page to load it
- Show what the cartridge *is* -- name, mapper, size, mirroring
- **Gamepad API**, so a real USB or Bluetooth pad works. This matters: the
  stated goal is a modern console, and a keyboard is not that. Keyboard stays
  as the fallback.
- Per-console button mapping, remappable, stored in the browser
- The existing analyser/synth/video tabs move behind a "developer" toggle --
  kept, not deleted; they are how everything here got debugged

## Step 3 -- Audio

The NES APU is missing, and a console without sound is not one. Two pulse
channels, triangle, noise, DMC. The output path already exists: the synth's
ring buffer streams audio to the browser over the same bus. This is a
self-contained addition and should land before a second console, because the
second console will want the same output path.

## Step 4 -- Sega Master System

The right second console. Not the Mega Drive -- see below.

- **Z80** -- a different CPU, but a well-documented one, and the same
  verification strategy applies: ZEXALL is the Z80's nestest. The test programs
  are already in `sim/roms/z80/`; the design note explains the shape the core
  needs and the mistake the first attempt made.
- **VDP** (315-5124): 256x192, tile-based, sprite table, line interrupt. It is
  closer to the NES PPU than it looks; the framebuffer path is unchanged.
- **SN76489 PSG**: three square channels and a noise channel. Small, once
  step 3 has built the output path.
- **Sega mapper**: three 16 kB banks, register-mapped at $FFFC-$FFFF. Much
  simpler than MMC3.
- Game Gear comes nearly free afterwards: the same hardware with a smaller
  viewport and a 12-bit palette.

Order within the step: Z80 + ZEXALL first, then VDP, then mapper, then PSG.
The CPU is the part that must be exactly right, and it is testable alone.

## Step 5 -- The shell, and the ESP32 front door

Designed in `docs/ARCHITECTURE.md`; the parts that exist are noted there.

The board's configuration flash is 8 MB, which is a shell plus three 2 MB core
slots -- so the library of cores and cartridges lives on an SD card on the
ESP32, and the flash is a cache of three. Power-up always loads address 0, so a
broken core cannot brick the board.

Done: `rtl/spi_flash.v` (writes the configuration flash from user logic, 3976
LUTs, no block RAM), `rtl/esp_link.v` and `sim/tb_esp_link.v` (the SPI slave,
verified at the 50 MHz / 10 MHz ratio it is specified at), and the ESP32 client
in `esp32/` -- Wi-Fi access point, web page, SD card, the protocol.

Not done, and next: `shell_top.v`, which is `spi_flash.v` plus `esp_link.v`
plus ICAPE2 and nothing else. Until it exists the ESP32 half has nothing to
talk to.

## Step 6 -- HDMI

Deferred until the connector arrives, and unaffected by everything above
because every console writes to the same framebuffer. 640x480 over TMDS,
OSERDESE2 at 251 MHz, differential pairs already confirmed present on the
board.

## Step 7 -- Bluetooth controllers

A companion ESP32 over UART, speaking to the joypad registers. The FPGA has no
USB host and will not grow one; pairing and the HID stack belong on a chip that
already has them.

---

## Explicitly not doing yet, and why

**Mega Drive / Genesis** -- ~~not yet~~, **started**. The Master System proved
the multi-console structure, so this is now the next console. The 68000 is
**built and passing 2598 checks** (`rtl/m68k.v`, `sim/tb_m68k.v`,
`sim/tb_m68krom.v`): 5688 LUTs,
1090 flip-flops, one DSP slice, no block RAM. See `docs/MEGADRIVE.md` for what
is in it and what is deliberately left out.

The two are wired together in `rtl/md_top.v` and pass an integration test
(`sim/tb_md_top.v`) in which a real cartridge program clears VRAM by DMA, sets
the VDP up through the memory map and draws a picture the testbench checks. The
Z80 is there too, with its RAM, both sound chips and the bus handover the 68000
uses to load a sound driver, and the cartridge runs through the cache. The whole
machine is 11294 LUTs, 5328 flip-flops, 38 block RAM tiles and two DSP slices --
eighteen per cent of the logic and twenty-eight per cent of the memory.

Still ahead of a running Mega Drive, in the order they have to happen:

1. **DDR3 and a cache.** The cache is **built and measured** (`rtl/cart_cache.v`,
   `sim/tb_cart_cache.v`): against a DDR3 model that takes 12 cycles for an open
   row and 30 for a closed one, a streaming read costs **one cycle of waiting per
   word** and a scattered one costs 34. A 68000 read is about 28 clocks, so the
   answer to "does DDR3 behind a cache look like a cartridge" is yes, with room
   to spare. 544 LUTs and three block RAM tiles.

   **The pinout is now recovered** -- `boards/qmtech_a100t/ddr3.xdc`, all 48
   signals, from the vendor schematic. It is 256 MB of Micron MT41K128M16 on
   bank 16. Pairing labels to pins by position alone is ambiguous, because the
   pins are evenly spaced and several offsets fit; the offset was settled by what
   DDR3 requires (DQS pairs on DQS-capable L-pairs, CK a true pair, each byte
   lane inside one byte group), which exactly one candidate satisfies. Chip
   select, the one signal the sheet leaves unlabelled on the FPGA symbol, is E22
   by an exact elimination: 26 non-data pins for 26 address/control signals, 25
   labelled. It is derived, not yet proven -- a MIG that calibrates is the proof.

   **The Mega Drive now builds as a core** (`tools/core.sh md`). It does not
   wait for DDR3 any more: `rtl/md_cart.v` answers cart_cache's 128-bit line
   interface out of block RAM, so the 68000, the VDP, the Z80 and the FM chip
   can be exercised on real hardware today. It costs 97.5 of the part's 135
   block RAM tiles and meets timing with 0.27 ns to spare.

   The limit is the cartridge: 128 kB. Mega Drive games start at 512 kB, so what
   this runs is test ROMs and homebrew, not Sonic. Nothing above md_cart knows
   or cares -- swapping it for the MIG changes one instantiation, which is why
   cart_cache was given a line interface in the first place.

   Two things the integration turned up, both of which had been waiting:

   * `console_sel` reset to CONSOLE_NES unconditionally, so any image without
     the NES in it came up having selected a core it did not contain, ran
     nothing, and showed a black screen -- while reporting "built: Master
     System, running: NES". The write path checked CORES_BUILT; the reset value
     went around that check rather than through it.
   * The Mega Drive is the only core that can address past the framebuffer. In
     H40 the VDP is 320 pixels wide and the buffer is 256, so those pixels are
     dropped rather than allowed to wrap onto the next line. A game in H40 shows
     its left three quarters, which is obviously wrong; wrapping would shear the
     picture diagonally, which looks like a broken VDP.

   **The MIG now builds.** `tools/core.sh md` produces a Mega Drive with its
   cartridge in DDR3: routed, timing met, 65.5 of 135 block RAM tiles instead of
   97.5. Thirty-two tiles came back and the cartridge ceiling went from 128 kB
   to 256 MB, which is the whole reason for doing this.

   It took four separate faults, and the order matters because the first one
   hid the rest:

   * **The build never set the part.** `synth_design` takes `-part`, so it looks
     handled -- but `read_ip` loads the IP into the session's implicit project,
     and that project sits on Vivado's default `xc7a12ti` until told otherwise.
     An IP customized for one part inside a project set to another is LOCKED,
     and a locked IP does not regenerate its output products. Implementation
     then runs against whatever netlist was already on disk. A corrected pinout
     could be generated, sit in the .xci, and never reach the bitstream. Fixed
     with one `create_project -in_memory -part` before anything is read.
   * **`ddr3_addr[2]` was on F16, a VCCO_16 power pad**, with eleven address
     lines shifted down behind it -- one row inserted by hand in the MIG wizard.
     `tools/migpins.py` now writes the .prj's pinout from ddr3.xdc so there is
     one place the numbers live, and `tools/vivado.sh mig` regenerates the
     controller without anybody typing 48 ball names into a dialog.
   * **ui_clk was in no clock group.** `set_clock_groups` named sys_clk without
     `-include_generated_clocks`, and ui_clk comes out of the controller's own
     MMCM hanging off sys_clk. So every crossing register in ddr3_mem.v was
     timed against eth_refclk as though the two were related: -6.9 ns of setup
     slack that did not exist.
   * **There is no chip select on this board.** The one that mattered. CS was
     placed on E22 by an elimination that assumed 26 control signals needed 26
     pins -- and counted a signal the board does not route. The DRAM is a single
     rank with CS# tied low. E22 sits outside every byte group at IOB_X0Y150,
     immediately below byte group T3, and a phaser-clocked command signal there
     drags the whole T3 data lane out of alignment. It reports as byte lane A's
     oserdes_clk and iserdes_clkdiv being unroutable, which reads like a broken
     data lane rather than one invented pin in the lane below it. The controller
     has to be told: `<emrCSSelection>` Disable.

   **The pinout is now confirmed, not derived.** ChinaQMTECH publishes
   `XC7A100T/Software_XC7A100T/DDR3.ucf` in QMTECH_XC7A75T-100T-200T_Core_Board,
   and all 47 signals match ddr3.xdc pin for pin. It also writes SSTL135
   throughout, which settles the 1.5 V / 1.35 V question that ddr3.xdc said to
   measure with a meter -- the board is the 1.35 V revision.

   The memory clock is 3077 ps (650 Mbps). Not a free choice: MIG only supports
   3000-3300 ps on this part, and picks its input clock as tCK x 13/8, so 3077
   is the one value in that window whose input lands on the 200 MHz the board's
   MMCM already makes. It is declared as 199.995 MHz against an actual 200.000,
   a 25 ppm difference and well inside the oscillator's own tolerance.

   **It calibrates, and a cartridge runs out of it.** Confirmed on the board:

       MEM 0x0010 -> 0x00000003    ddr3 present=1 calibrated=1

   Calibration is the part a bitstream cannot argue with. The PHY only reports
   it after write levelling, read levelling and DQS gating have all completed
   against the actual DRAM, so it says the pinout is right on all 47 signals and
   the rail really is 1.35 V.

   Then the whole path: `tools/md/mdtest.py`'s cartridge loaded into DDR3 over
   fpgalink and run. The 68000 fetched its reset vector and every instruction
   after it out of DDR3 through cart_cache, cleared VRAM by DMA, set the VDP up
   and drew its tile -- a solid red cell top left on black, captured back off the
   board as `build/hw_md_ddr3.png`. Host write path, CPU read path and the cache
   all working on real hardware, not in a model.

   (The colour strip along the bottom of that capture is not a fault. The Mega
   Drive draws 224 lines into a 240-line framebuffer, so rows 224-239 still hold
   whatever the last core left there -- 8 colours x 512 px is exactly 256 x 16.)

   `init_calib_complete` now reaches the host at SYS 0x0010, bit 0, with bit 1
   saying whether the image has DDR3 in it at all. Before that, a memory that
   never trained and a console that was never going to draw were the same black
   screen.
2. **VDP 315-5313** -- **done**, as far as the video path goes. The control
   port, all three memories, video timing, both scroll planes, the window layer,
   sprites, both interrupts and all three kinds of DMA, passing 72 checks
   (`rtl/md_vdp.v`, `sim/tb_md_vdp.v`): 1426 LUTs and 16 block RAM tiles.
3. **YM2612** -- **built**, and it makes a sound. Register ports, timers, DAC,
   phase and envelope generators, feedback and all eight algorithms, passing 33
   checks (`rtl/ym2612.v`, `sim/tb_ym2612.v`). Not verified against real
   hardware: the exact envelope rate steps, the operator ordering, and detune and
   the LFO, which are not implemented. All three are audible; none stops a sound
   driver from working.
4. ~~**Controllers**~~ -- done, three-button pads on both ports, checked by a
   program that reads both halves and gets different answers.
5. ~~**The video path out to the framebuffer**~~ -- done. `rtl/md_console.v`
   carries the four clock enables and the colour conversion, checked by
   `sim/tb_md_console.v`. It wants a 53.693 MHz clock from an MMCM, because every
   divisor in a Mega Drive is an integer only from that.
6. ~~**The MIG.**~~ **Done, and proven on hardware** -- see step 1 above for the
   four faults that took. It calibrates, and a cartridge runs out of DDR3. What
   is still worth measuring is how the cache's latency model compares to the
   real thing now that there is a real thing to compare against.

**Mappers beyond MMC3.** ~~MMC1 and UxROM~~ -- both **done**, and both verified
by a cartridge that proves its own banking: seven switchable banks each holding
a routine that writes its own number, walked by the fixed bank. If banking
failed, the same number would appear seven times. `sim/tb_mapper.v` runs the
same cartridge built for either mapper, so one known answer exercises two very
different protocols -- UxROM takes a bank number in one plain write, MMC1 takes
it one bit at a time over five.

Also added with them: CHR RAM, for the many cartridges that carry no tile ROM
and build their tiles at runtime, and four-way mirroring, because MMC1 can point
both name tables at the same kilobyte and a single vertical/horizontal flag
cannot say that.

Still not done: mappers beyond these four.

---

## Session state, end of day

**Working and verified on hardware**

- NES and Master System cores, both rendering real commercial games
- The cartridge cache, in simulation: a streaming read costs one cycle of
  waiting per word against a pessimistic DDR3 model, which settles the question
  the whole Mega Drive plan was waiting on
- A Mega Drive, in simulation: the 68000, the VDP and the Z80 wired together,
  running a cartridge program that clears VRAM by DMA, sets the VDP up through
  the memory map, draws a picture the testbench checks, and hands the Z80 a
  program to run and reads back its answer
- The Mega Drive VDP, in simulation: 72 checks covering the control port, all
  three of its memories, video timing, both scrolling planes, the window layer,
  sprites, both interrupts and all three kinds of DMA
- The 68000, in simulation: 126 checks across fourteen hand-written programs,
  plus 2472 generated by sweeping a Python model of the processor's arithmetic
  against the Verilog. Every addressing mode, the full ALU with its condition
  codes, multiply and divide, MOVEM, the bit instructions, and exceptions
- The shell boots from flash on its own and answers over Ethernet
- The ESP32-S3 link: `A5 01 00 00` at 10 MHz, both directions
- ESP32 firmware: access point, Wi-Fi join with credentials in NVS, web UI,
  core upload straight from the browser

**The flash, and why it looked broken** -- RESOLVED

For most of a day the shell could not reach the flash chip. The logic analyser
built into the shell showed the FPGA doing everything right -- sck moving at
6.25 MHz, mosi decoding as $9F, cs framed correctly -- and miso flat, never
answering. Ruled out along the way: the pin assignment, SPIx4 versus SPIx1, the
chip being in quad or XIP mode, the clock rate, and the controller logic, which
was verified against a behavioural N25Q model. The last suspect standing was
whether CCLK actually leaves the H13 pad through STARTUPE2, which the analyser
cannot see.

It was none of those. Two things were wrong at once, and neither was in the
design:

1. **The barrel jack was unplugged.** The board ran on USB power alone. That is
   enough for the FPGA fabric and not, apparently, for the flash -- which
   explains the symptom exactly: the FPGA drives the bus correctly and nothing
   answers. (Stated as the best explanation rather than a proven one; what is
   certain is that with the jack in, the flash answers.)
2. **The flash was blank.** A verify against the shell image failed at byte 42,
   FF against 00. With nothing to load, the FPGA never configured at power-up --
   DONE read 0 while the JTAG chain was perfectly healthy.

What it took to be sure, and what to do next time the board looks dead:

    JTAG chain empty        -> power or cable, NEVER a bad bitstream. The TAP
                               answers whenever VCCINT and VCCAUX are present,
                               whatever is in the flash.
    chain fine, DONE = 0    -> the flash, not the FPGA. Verify the image against
                               a known good .mcs before assuming anything else.
    both fine, nothing on   -> then, and only then, start suspecting the design.
    the network

After erasing and rewriting the flash, all four paths work: the FPGA boots from
flash on its own, fpgalink answers "SHEL" over Ethernet, the ESP32 reports
"FPGA: answering, protocol 1, core 0", and the shell reads the flash's JEDEC ID
from user logic as $20 $BA $17 -- Micron, N25Q, 64 Mbit. Exactly the right chip.

The hardware was never the problem, and neither was the shell.

### The half-bit that broke every command except one

Writes still did nothing afterwards, and the reason turned out to be one line.
The bit engine did this:

    if (!sclk) begin
        spi_mosi <= shift_out[7];    // present the bit
        sclk     <= 1'b1;            // ...and clock it, in the same instant
    end

Both are non-blocking assignments in one cycle, so MOSI moved at exactly the
moment the flash sampled it. Zero setup time. The part latched a line that was
still in transit and got the old bit OR the new one, so every byte arrived as
`x | (x >> 1)`.

That is not data corruption. It is a different command, obeyed perfectly:

    $9F read-id      -> $DF   unknown; MISO idles high, the id reads as FFFFFF
    $06 write-enable -> $07   unknown; writes are never enabled
    $05 read-status  -> $07   unknown; status reads FF, bit 0 set, so a poll for
                              "still busy" NEVER ENDS -- the 390-second erase
    $D8 sector-erase -> $FC   unknown
    $02 page-program -> $03   a READ, which is why programming was harmless
    $03 read         -> $03   UNCHANGED

$03 is the one opcode this mangling leaves alone. So reads were flawless while
nothing could be written -- which is the most misleading symptom possible, and
is why it survived a full day of looking directly at it.

How it was actually pinned down, after guessing failed: read a page through the
shell, then search the .mcs that was written to the flash for those same bytes,
and see where they really came from.

    asked $200000 -> came from $300000   = $200000 | $100000
    asked $200080 -> came from $3000C0   = $200080 | $100040
    asked $300000 -> came from $380000   = $300000 | $180000

Three data points name the transform exactly, and the transform names the cause.
Ask the hardware where the data came from; do not theorise about why it is wrong.

**The rule this leaves:** in SPI mode 0 MOSI changes on the FALLING edge, never
the rising one. Presenting a bit in the same cycle that clocks it simulates
perfectly and fails on every real part -- Verilog applies both updates before the
model's sampling block runs, so the model always sees the bit you meant.

`sim/spiflash_model.v` now enforces `SETUP_NS`, and when it is violated it does
not merely warn: it latches `previous | current`, exactly as the silicon did. Put
the old code back and all ten checks fail. A model that is forgiving about timing
is not a model of the part -- it is a model of your intentions.

Confirmed on the board afterwards, which is the only confirmation that counts:

    chip id                    20 BA 17   Micron N25Q, 64 Mbit
    erase a sector             0.7 s      previously polled forever
    program a page             byte-exact on read-back
    the page next to it        untouched

Both of the flash bugs were real and both had to go. The deselect time was found
first and fixed nothing visible on its own, which is worth remembering: fixing a
genuine bug and seeing no change does not mean you were wrong about it.

### Installing goes over JTAG anyway

`/api/shell/install` drives Vivado rather than the shell's own flash engine, and
stays that way now that the engine works. Three reasons, none of them doubt:

  * it works while a CONSOLE is running -- the shell is not involved, so the
    board does not have to be put back into the shell first, and a board sitting
    in a core is exactly when somebody wants to change which one;
  * Vivado erases, writes and verifies the whole 8 MB as one operation that
    either completes or does not;
  * it writes the shell and the core together, so a board cannot end up with a
    new core under an old shell.

It costs about 110 seconds, most of it erasing. `/api/shell/reboot` reloads the
chip from flash over the same cable, which is the only way back to the shell from
inside a core -- a core has no register that reconfigures the board.

is not driving the pad" from "the pad is driving and the chip ignores it", and
those two have completely different fixes.
