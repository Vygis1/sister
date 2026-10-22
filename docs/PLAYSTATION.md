# PlayStation

How the PlayStation core is built, what it needs, and how it is checked. The user guide is
[GUIDE.md](GUIDE.md); the other systems are in [CONSOLES.md](CONSOLES.md).

## What it needs

- **A BIOS.** A 512 kB `SCPH*.BIN` (SCPH-1001 or a sibling) in `/bios`, `/roms/ps1` or `/roms` on
  the SD card. The ESP32 loads it into DDR3 each time a PlayStation game starts. None is included.
- **Discs.** In `/discs` or `/roms/ps1`: a `.bin` of raw 2352-byte sectors, or a `.cue` whose
  tracks are `BINARY` `.bin` files. A cue that names MP3 or WAV audio files is refused. A cue is
  listed once, under its own name; the track files it names are not listed separately.
- **A memory card** is made for you: `/saves/card1.mcr` (raw 128 kB, the format DuckStation
  uses), created and formatted when it is missing.

The core is built with `./tools/core.sh ps1` (`EFFORT=1` to meet timing). It runs at 50 MHz.

## Overview

```
                +---------+     +-------+    +-------+     +------------+
  pads + card ->|  SIO0   |     |  GTE  |<-->| R3000 |<--->| I-cache 4K |
                +---------+     +-------+    +-------+     | D-cache 4K |
                +---------+                      |         +------------+
  ESP32 sectors>| CD-ROM  |--+                   v                |
  (cd_feed.v)   +---------+  |   +-----+   +------------+   +-------------+
                             +-->| DMA |-->| 128 kB L2  |-->|             |
                +---------+  |   +-----+   | (BRAM)     |   |  memory     |
                |  MDEC   |<-+       |     +------------+   |  arbiter    |---> DDR3
                +---------+          |                      |  (7 ports)  |
                |   GPU   |<---------+                      |             |
                | raster  |--> VRAM cache, block writer --->|             |
                | scanout |--> frame in DDR3 ------------->|             |----> HDMI
                +---------+                                 |             |
                |   SPU   |--> 44.1 kHz stereo ----------------------------> HDMI audio
                +---------+---------------------------------+-------------+
```

## Memory

Every PlayStation memory lives in DDR3, behind a seven-port arbiter (`mem_arb.v`) that works
in 16-byte lines. The ports are the CPU's cache, the VRAM cache, the GPU's block writer, the
frame capture, the loader (BIOS and memory card), the SPU, and the texture prefetch.

| DDR3 address | What |
|---|---|
| 0 MB | VRAM, 1 MB (1024 x 512 x 16 bits) |
| 1 MB | main RAM, 2 MB |
| 3 MB | BIOS, 512 kB |
| 4 MB | the displayed frame, for HDMI |
| 8 MB | SPU RAM, 512 kB (the top 128 kB is in block RAM instead) |
| 9 MB | memory card 1, 128 kB; card 2 at +128 kB |

The 1 kB scratchpad is block RAM. DDR3 answers in tens of clocks, so everything that is read
often has a cache in front of it.

## CPU — `r3000.v`, `ps1_icache.v`, `ps1_cache.v`

A MIPS I R3000A as the console has it: no TLB and no FPU, the segment bits stripped to make a
physical address, and stores dropped while SR.IsC isolates the cache. It has the full integer
set, the four unaligned loads and stores, multiply and divide into HI/LO with the chip's
divide-by-zero results, COP0 (SR, CAUSE, EPC, BadVaddr, PRID), exceptions and interrupts, and
COP2 for the GTE.

Both delay slots behave as on the chip: a branch's delay slot always runs, and the instruction
after a load reads the register's old value. Loads from MFC0, MFC2 and CFC2 are delayed the
same way.

The caches:

- **Instruction cache:** 4 kB, 256 lines of 16 bytes, direct-mapped, as on the chip. A hit is
  answered in the same cycle.
- **Data cache:** 4 kB, answered in the same cycle. The console has no data cache, only the
  scratchpad; this one stands in for RAM that is much slower here than on the console.
- **L2:** 128 kB, write-back, in block RAM, with a store buffer. The DMA controller reads and
  writes RAM through its second port, so the DMA sees what the CPU just wrote.

**Pace.** The console's timers, video and sound always run on the console's 33.8688 MHz,
derived from the core clock. By default the CPU may run on every core clock, ahead of the
console's pace. A game still waits for its vertical blanks, so it does not run faster than the
console; it misses fewer of them. Control register `0xEC` bit 12 holds the CPU to the console's
33.8688 MHz, and bit 13 (on by default) lets the drawing engine run past the chip's fill rate.
`tools/ps1/ps1suite.py` sets the console's pace for the timing tests.

**Checked by:** `sim/tb_r3000.v`, running a self-checking program from `tools/ps1/mipstest.py`
that computes every case in Python and on the CPU and stops at the first disagreement.

## GTE — `ps1_gte.v`

The geometry coprocessor: perspective transformation, lighting, depth cueing and the rest of
the command set, with the chip's 44-bit accumulators, flags, saturation and divide.

It is checked two ways:

- against a Python model (`tools/ps1/gte.py`) with a generated sweep (`tools/ps1/gtetest.py`,
  `sim/tb_gte.v`);
- against results recorded on a real console (JaCzekanski's GTE fuzz log from
  [ps1-tests](https://github.com/JaCzekanski/ps1-tests), converted by `tools/ps1/gtehw.py`).

## GPU — `ps1_gpu.v`, `ps1_raster.v`, `ps1_gpu_blk.v`, `ps1_vram_port.v`

**Commands:** the GP0 drawing set (fills, polygons, lines, rectangles, VRAM-to-VRAM, CPU-to-VRAM
and VRAM-to-CPU copies, the drawing environment) and the GP1 display set.

**The rasteriser** is a pipeline that draws two pixels a clock: flat, Gouraud and textured
fills, all texture depths, the semi-transparency modes, dithering and the mask bit. Edges are
stepped incrementally.

**Textures** come through a 4 kB tiled cache, so a span that walks down a texture keeps the
rows above it. A prefetch reads tiles the rasteriser will need soon on its own arbiter port.
The current palette (CLUT) is kept on chip.

**Writes** are gathered into 32-byte blocks and posted to the arbiter as masked line writes,
so drawing does not wait for read-modify-write cycles. Reads of a line still being written are
forwarded or held until the write lands.

**Scanout:** the displayed area of VRAM, 256 to 640 pixels wide, 15-bit or 24-bit colour,
including interlaced 480-line modes. Each frame is written to DDR3 at 4 MB (`fb_ddr.v`) and
read from there a line at a time for HDMI, scaled to 640 x 480. The menu's scaling and
scanline settings apply.

## MDEC — `ps1_mdec.v`

The motion decoder that plays the games' video: run-length decoding, dequantisation, the IDCT
and YCbCr to RGB, at 4, 8, 15 and 24 bits, on DMA channels 0 and 1. The arithmetic is
Mednafen's. It is checked word for word against the model `tools/ps1/mdec.py` by
`sim/tb_ps1_mdec.v`. [MDEC_NOTES.md](MDEC_NOTES.md) describes the chip and where the sources
disagree.

## SPU — `ps1_spu.v`, `ps1_spu_gauss.v`, `ps1_spu_ram.v`

- 24 ADPCM voices with Gaussian interpolation, the ADSR envelope, pitch modulation and noise.
- The reverb, SPU RAM transfers (DMA channel 4) and the SPU interrupt.
- CD audio and XA mixed in at the CD volume, and into the reverb.
- The four capture buffers (CD left and right, voices 1 and 3), which can raise the interrupt.

One stereo sample every 768 console cycles: 44.1 kHz, sent to HDMI. The reverb's work area,
the top 128 kB of SPU RAM, is in block RAM; the rest is in DDR3.

`tools/ps1/spu_ref.py` is a Python model written from psx-spx, with DuckStation and Mednafen
where they differ. `sim/tb_ps1_spu.v` checks the hardware against it bit for bit.

## CD-ROM — `ps1_cdrom.v`, `cd_feed.v`

**The drive controller:**

- the command set with its INT1 to INT5 responses, and the delays between them;
- seeking, and reading at single and double speed, into a ring of eight raw sectors;
- DMA channel 3, and byte reads through the data register;
- a table of contents of up to 99 tracks, sent by the ESP32;
- CD audio: Play, report mode, auto-pause, GetTN, GetTD, GetlocP, Mute and the volume matrix;
- XA-ADPCM: Setmode's real-time audio bit, the file and channel filter;
- each data sector's EDC is checked, and a sector that fails is asked for again.

With no disc in, it reports the lid open and the motor off, and the BIOS shows its own menu.

**The sectors** come from the ESP32's SD card over the ESP link (`cd_feed.v`, commands `0x30`
to `0x32`). The drive says which sector it wants next and how much room it has. On the ESP32
(`esp32/console/console.ino`) one task reads ahead from the card into a 128-sector window and
another sends the wanted sector, so the two SPI buses work at once.

**XA audio** is decoded on the ESP32. The drive queues the address of each XA sector that
passes the game's filter (16 entries). The ESP32 decodes it and resamples it to 44.1 kHz
(`esp32/console/xa.h`, a port of the decoder in `tools/ps1/cdaudio.py`, which follows
DuckStation), and writes the samples into a 4096-sample FIFO in the drive.
`tools/ps1/xatest.py` checks `xa.h` against `cdaudio.py` word for word on real sectors.

**CD audio tracks** are 2352-byte sectors of 16-bit stereo PCM. They reach the drive like data
sectors and are told apart by their missing sync pattern.

## Pads and memory cards — `ps1_sio.v`

Each of the two ports has a digital pad with all sixteen buttons and a memory card. The cards
answer the read, write and get-ID commands byte for byte as DuckStation's do (`sim/tb_ps1_mcard.v`).

The ESP32 loads `/saves/card1.mcr` into card 1 when a game starts. Every sector a game writes
is queued on the board, and the ESP32 copies it back into the file. The ESP32 does not load a
card into slot 2.

## The rest

- **DMA** (`ps1_dma.v`): channels 0 and 1 (MDEC), 2 (GPU, including linked lists), 3 (CD-ROM),
  4 (SPU) and 6 (ordering-table clear). The PIO channel completes at once.
- **Timers** (`ps1_timers.v`): the three root counters with their clock sources and modes.
- **Interrupts** (`ps1_irq.v`): I_STAT and I_MASK, with the console's eleven sources.

## On the board

These tools talk to the board through `tools/pad.py`:

| Tool | What it does |
|---|---|
| `tools/ps1/ps1fps.py` | the game's frame rate, from its display flips |
| `tools/ps1/espshot.py` | the displayed frame as a PNG |
| `tools/ps1/bootloop.py` | starts a game several times and checks that it boots each time |
| `tools/ps1/ps1suite.py` | runs [ps1-tests](https://github.com/JaCzekanski/ps1-tests) and compares with the real console's results (needs a `JTAG=1` debug image) |
| `tools/ps1/dssuite.py` | runs the same tests in DuckStation, to see which ones it passes |
| `tools/ps1/exedisc.py` | turns a PS-X EXE into a bootable disc image |
