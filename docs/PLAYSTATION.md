# PlayStation

Where this stands, what the target is, and the order the rest happens in. Each
step is testable on its own, and none of them waits on a later one.

## The target

**The BIOS menu on the dashboard.** Power on with no disc and a PlayStation
shows the Sony logo, the PlayStation logo turning in 3D, and then a menu for
the memory cards and the CD player. Getting there needs the CPU, the GTE (the
logo is 3D), the GPU (Gouraud polygons, textured rectangles for the font,
fills and copies), the DMA controller, the interrupt controller and the root
counters. It does not need the SPU or the CD drive: the menu appears without
either.

That is the milestone because it is the smallest thing that is visibly a
PlayStation, and because everything a game then needs sits on top of it.

## What is needed from outside

**A BIOS image.** SCPH-1001 or any of its siblings, 512 kB. There is no
PlayStation without it -- the logo screen *is* the BIOS. Without one, every part below is built against its own
test program, the way the other three CPUs were; the BIOS boot is the
integration test that runs the moment the file exists.

**A game disc image**, raw MODE2/2352 (.bin). Development used a retail copy
of Crash Bandicoot (USA) dumped by its owner. Neither a BIOS nor any game is
part of this repository; bring your own.

## Done

### The CPU -- `rtl/r3000.v`

A MIPS I R3000A as the console has it: no TLB, no FPU, the segment bits
stripped to make a physical address, SR.IsC honoured by dropping stores. Every
integer instruction, the unaligned four, multiply and divide into HI/LO with
the chip's own divide-by-zero answers, COP0 with SR/CAUSE/EPC/BadVaddr/PRID,
exceptions with the right code and EPC and BD, RFE, six interrupt lines.

Both delay slots are what the architecture says they are. A load's destination
is not visible to the next instruction, which reads the old value; the sweep
has a case for it, and it was the one case that failed on the first run,
because the first version wrote the register one fetch too early. A CPU that
interlocks loads runs PlayStation code wrongly in ways that take a long time to
find, because the code was written for the one that does not.

Verified by `tools/ps1/mipstest.py` against `tools/mipsasm.py`: a Python model of
the instruction set generates a 28,159-word program that computes every case
twice and stops at the first disagreement. **2,251 checks**, `sim/tb_r3000.v`:
the ALU on the flag boundaries, both immediate extensions, shifts by immediate
and by register, MULT/MULTU/DIV/DIVU including the overflow and divide-by-zero
results, every load and store width, LWL/LWR/SWL/SWR at every alignment, the
load delay slot, every branch taken and not with the slot proven executed,
JAL/JALR/BGEZAL link values, overflow/SYSCALL/BREAK/address-error exceptions
with EPC and BD, and an external interrupt.

Multi-cycle rather than pipelined: three or four enables per instruction, with
the bus answering two enables after the address like everything else here. Not
fast. Fast is a replacement for later, and the sweep says whether the
replacement is right.

## First light

The R3000, the GPU, the VRAM cache and the register fabric run together
(`rtl/ps1_top.v`, `sim/tb_ps1.v`): the CPU executes tools/ps1/ps1demo.py's program
out of a boot ROM, writes GPU commands itself, and draws a boot screen -- a
Gouraud-shaded diamond and a menu bar, rendered to VRAM in DDR3 and scanned out
320x240. `docs/ps1_boot.png` is that frame, straight off the simulated display.

Three bugs found getting there, each by a measurement:

* The GPU's command FIFO pop was registered, so `f_rd` advanced a cycle late
  and every multi-word command read its own header as its first argument.
  Combinational now.
* The CPU bus had two pipeline registers where the CPU allows one wait cycle,
  so it read the previous fetch -- every branch's delay slot ran against the
  wrong instruction and the program wandered off its own end. One register now.
* The boot program polled "GPU fully idle" before every command WORD, but a
  multi-word command makes the GPU busy after word one, so the CPU would not
  send word two and the engine waited forever. It polls once per command and
  pushes the whole command -- header and arguments -- into the sixteen-deep
  FIFO at once.

## Next, in order

1. **The GTE.** COP2: RTPS/RTPT, NCLIP, AVSZ, MVMVA, NCDS and the rest of the
   ~30 ops, 16-bit fixed point with the flag register. Same method: a Python
   model and a generated sweep.
2. **The machine.** `rtl/ps1_top.v`: the CPU behind an instruction cache and a
   line buffer into DDR3 through `mem_arb`, 2 MB RAM and the BIOS in DDR3, the
   1 kB scratchpad in block RAM, the interrupt controller at $1F801070, the
   three root counters at $1F801100, the DMA controller at $1F801080, stubs
   at the SPU, CD and joypad addresses so the BIOS's probes get answers.
3. **The GPU.** VRAM in DDR3 -- 1 MB, 1024x512x16 -- through the arbiter.
   GP0: fills, CPU-to-VRAM, VRAM-to-VRAM, flat and Gouraud triangles and
   quads, textured rectangles with the CLUT. GP1: display area and enable.
   The display scans the active area into the 320-wide framebuffer.
4. **The BIOS boot**, which is 1-3 running the real thing. Then the disc.

## Resources

The Mega Drive core sits at 18.5k LUTs and 81.5 block RAM tiles with its
cartridge in DDR3. A PlayStation is its own image and gets the whole chip:
63,400 LUTs, 135 tiles, 256 MB. The GPU is where the LUTs go.

## Status 2026-09-18: the BIOS boots and runs on hardware

Five bugs fixed, all verified in sim and on the A100T, no regressions:

* **CPU cache stall** (`ps1_top.v`) — the `served` flag leaked a registered cache
  ack from one access onto the next, corrupting stores and branch delay slots.
  Pinned to one presentation. `tb_ps1_bios` PASSES.
* **DMA request pulse** (`ps1_dma.v`) — `r_req` was one cycle; the shared cache
  only takes a port-B request while idle, so it was missed and the DMA hung.
  Held until `r_ack` in every wait state.
* **GPU VRAM request pulse** (`ps1_gpu.v`) — `v_req` cleared unconditionally each
  cycle; the draw engine hung mid-polygon. Default changed to clear on `v_ack`.
* **Arbiter re-issue** (`mem_arb.v`) — held `m_req` as a level; a MIG (and the sim
  model) re-accepts a held command every ready cycle, flooding the read queue with
  duplicates so real data never routed back. Rewrote to one command per pulse.
  Only bites with >1 concurrent client (MD used one port). Regression tests pass.
* **IRQ source mapping** (`ps1_top.v`) — DMA/timer/GPU interrupt lines were on the
  wrong bits; the BIOS's boot handlers never saw them. Corrected to 0 VBLANK,
  1 GPU, 2 CDROM, 3 DMA, 4/5/6 TMR.

On hardware the BIOS clears RAM, relocates and runs its kernel, VSync fires (~78 Hz),
interrupts are serviced, the GPU actively draws 300+ commands, and the display
enables. The screen shows the BIOS's rendered background.

**Next: the GTE (COP2).** The visible frame is the background; the PlayStation logo
does not appear because its 3D vertices come from the GTE, still a stub. Getting the
logo and then the memory-card/CD menu on screen is the GTE step (docs above), built
the same way the CPUs were: a Python model and a generated self-checking sweep.
Debug registers for continued work are exposed via console_top ctrl reads 0x38-0x50.

## Status 2026-09-29: games, sound, memory card

Everything above is history; this is where the machine stands.

* **It plays.** The BIOS boots from reset to its menu or to a disc, and Crash
  Bandicoot runs at 30 fps in its levels. The GTE is done, and so are the GPU
  (a 2-pixel-a-clock rasteriser with a tiled texture cache), the SPU (24 voices,
  ADSR, reverb, bit-exact against `tools/ps1/spu_ref.py`), DMA, the timers, and the
  CD-ROM controller.
* **The CPU runs on every 50 MHz clock** by default (ctrl 0xEC bit 12 holds it
  to 33.8688 MHz instead). It takes three clocks for a load where the R3000
  takes one, and at the console's clock the levels ran at 20 fps. Timers, video
  and sound keep the console's clock either way. Its cache is 64 kB of block RAM
  (`ps1_cache` BRAM mode).
* **The disc** comes from the PC over Ethernet (`rtl/host_cd.v`, the server's
  HostDisc), or from the ESP32's SD card (`rtl/cd_feed.v`). With no disc in, the
  drive reports its lid open and motor off (status 10h), as DuckStation's does,
  and the BIOS shows its menu.
* **The memory card** is in slot 1 (`rtl/ps1_sio.v`). It answers the read,
  write and get-ID commands byte for byte as DuckStation's does, and it is
  checked by `sim/tb_ps1_mcard.v`. Its 128 kB are in DDR3 at 9 MB. The server
  loads a `.mcr` file there with the BIOS and copies every sector the console
  writes back into the file (a queue at ctrl 0x138). On the board: Crash's
  LOAD GAME lists a save from the file, and deleting that save in the BIOS
  card manager changes exactly its directory frame in the file on the PC.
* **Not done:** video out of the board itself (the picture goes to the
  browser).

## Status 2026-10-01: CD audio, XA, capture buffers, port 2

* **The table of contents** is two LUT-RAM tables in `ps1_cdrom.v`: {audio,
  start LBA} and {mm, ss} per track, with the lead-out in entry 0. The PC
  writes them at ctrl 0x5000 + 4*entry; entry 0xFF is {first, last}. They have
  exactly two read ports: the track finder's scan, and the command in hand
  (Play's track, GetTD's track). A constant-index read once made Vivado build
  them as 128 x 25 flip-flops with a 128-way multiplexer per read, 2,800 LUTs,
  and the image no longer routed. Its warning was "not inferred as ram due to
  incorrect usage".
* **CD audio** uses the data ring. Play pops a sector when the player has
  played the last one, and the player reads 4 bytes a 44.1 kHz tick. Audio
  sectors skip the header check, since they have none. They are told apart by
  their missing sync pattern. A data read that meets one passes over it with no
  INT1, as DuckStation's drive does. Before that fix, the BIOS sat at its logo
  with an audio CD in. A read that reaches the lead-out ends with INT4 a sector
  later.
* **The output** goes through the volume matrix, saturated. The game writes
  the four volumes at index 2 and 3, and they take effect on Apply (index 3,
  1F801803 bit 5). The SPU mixes it at the CD volume
  when SPUCNT bit 0 is set, and into the reverb with bit 2.
* **XA.** Setmode bit 6 routes real-time audio sectors away from the CPU. With
  bit 3, only the Setfilter file and channel are kept. Each kept sector's LBA
  goes into a 16-entry queue (ctrl 0x13C). `pc/server.py`'s XaPump reads the
  sector from the disc and decodes it with `pc/cdaudio.py`. That is
  DuckStation's ADPCM, its 7-phase zigzag resampler for 37.8 kHz, and
  Mednafen's table for 18.9 kHz. The pump pushes {R, L} words into a
  4096-sample FIFO (ctrl 0x6000). ctrl 0x140 counts the drive's flushes, and a
  new count resets the decoder. With no filter, the PC follows DuckStation's
  "current file" rule.
* **Capture buffers.** Each tick the SPU writes CD left, CD right, voice 1 and
  voice 3 at 000h/400h/800h/C00h + 2*position, as single masked halfwords at
  the lowest memory priority. CD audio is captured raw, before the CD volume,
  and always, as psx-spx and DuckStation say. A write on the IRQ address raises
  the IRQ. SPUSTAT bit 11 is the half-buffer flag. `tb_ps1_spu` checks every
  capture write and the IRQ.
* **Port 2.** JOY_CTRL bit 13 selects the second pad and card. Card 2 is at
  DDR3 9 MB + 128 kB. The save queue (ctrl 0x138) carries the slot in sector
  bit 10.
* **On the board:**
  * `tools/ps1/ps1cdtest.py` plays channel 3 of eight interleaved XA channels at
    700 Hz, and none of the others. It then plays an MP3 track at 880 Hz.
  * The real BIOS opens its CD player for an MP3+WAV audio CD
    (`tools/ps1/mktestdisc.py audio`), and one press of Play gives both tracks in
    full: 440/660 Hz, then 330 Hz, then a stop at the lead-out.
  * `tools/ps1/ps1slot2test.py` passes.
  * Crash still runs its levels at 30 fps (`tools/ps1/ps1frameevents.py`: 298
    frames in 10 s, every one two vsyncs).
  * Area: 55.8k LUTs (88%), 99.4% of slices, slack 0.077 ns. The worst path
    is the CPU's address into an SPU register's write enable, 21 levels and
    76% routing. A register stage on the SPU's register writes is the next
    step if it gets thinner.
* **`tools/ps1/ps1bench.py` undercounts.** It takes flips from ctrl 0x6C, the
  GPU's display area, and keeps only the X start. Crash's two buffers are
  stacked in Y, so X never changes. Use `tools/ps1/ps1frameevents.py`.
