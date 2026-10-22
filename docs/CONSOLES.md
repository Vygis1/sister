# The consoles

How each machine is built, and how it is checked. (The stand-alone console's
user guide is [GUIDE.md](GUIDE.md).)

### NES — `rtl/nes.v`, `cpu6502.v`, `ppu.v`, `apu.v`, `mapper.v`

- **6502:** cycle-accurate, NMOS quirks included, and without decimal mode, as
  on the 2A03. It passes Klaus Dormann's functional test and matches the nestest
  log for all 8,991 logged instructions, including the undocumented opcodes.
- **2C02 PPU:** background, sprites, sprite-zero hit and the real frame
  geometry, with pixels shown 8:7 wide as on a television.
- **APU:** five channels and the non-linear mixer.
- **Mappers:** NROM (0), MMC1 (1), UxROM (2) and MMC3 (4), including MMC3's
  A12 scanline counter that games use for split screens.

### Master System — `rtl/sms.v`, `z80.v`, `vdp.v`, `psg.v`

- **Z80:** passes ZEXDOC and ZEXALL on the board.
- **VDP:** background, sprites and interrupts. The sprite fetch is reordered so
  the first tile of each line is ready in time.
- **SN76489** sound, and the Sega mapper.

### Mega Drive — `rtl/md_console.v`, `m68k.v`, `md_vdp.v`, `md_sound.v`, `ym2612.v`

- **68000:** checked by a self-checking test program assembled in this tree
  (`tools/md/m68kasm.py`), which covers results, condition codes and addressing
  modes separately.
- **VDP:** planes, sprites and all three DMA modes.
- **Z80 sound CPU:** with its bus handover and bank register.
- **Sound chips:** the SN76489, and a YM2612 FM chip computed in decibels, as
  the real chip is.
- **Cartridges** are read from DDR3 through a cache, so games of up to 4 MB fit.

### Game Gear — `rtl/sms.v` with `GG=1`

- The Master System core, with three Game Gear differences: the 12-bit palette (CRAM written a
  byte pair at a time), the START button on port 00h, and stereo through port 06h.
- **LCD:** the 160 x 144 window (rows 24-167, columns 48-207 of the VDP's picture), shown
  tripled.

### Game Boy / Game Boy Color — `rtl/gb_top.v`, `gb_cpu.v`, `gb_ppu.v`, `gb_apu.v`

- **SM83:** passes all 500,000 SingleStepTests cases, blargg's `cpu_instrs` and
  `instr_timing`.
- **PPU:** dmg-acid2 and cgb-acid2 pass pixel for pixel in simulation; cgb-acid2 also passes
  on the board.
- **Color:** VRAM banks, tile attributes, palettes, OAM priority, double speed and HDMA. The
  cartridge header picks the mode.
- **Cartridges:** MBC1, MBC3 and MBC5, read from DDR3 through a cache.

### Game Boy Advance — `rtl/gba_top.v`, `arm7tdmi.v`, `gba_ppu.v`, `gba_snd.v`, `gba_ewram.v`, `gba_rtc.v`

- **ARM7TDMI:** one instruction at a time with the pipeline modelled. It passes 2,204,782 of
  the 2,204,858 SingleStepTests cases; the rest are the reference's multiply-flag artefact.
- **Bus:** wait states and prefetch at the console's own cycle timing; EWRAM and the cartridge
  in DDR3.
- **Picture:** text and affine backgrounds, bitmap modes, sprites, windows, blending and mosaic,
  checked pixel for pixel against a reference renderer (`tools/gba/ppuref.py`) on Tonc's demos.
- **Sound:** the Game Boy's four channels plus the two sample FIFOs. Also DMA, timers and the
  cartridge clock (Seiko S-3511).
- **BIOS:** the open Cult-of-GBA BIOS is built in (MIT, `rtl/LICENSE-gba-bios`). A real one in
  `/bios/gba_bios.bin` is used instead when present.

### PC Engine — `rtl/pce_top.v`, `huc6280.v`, `pce_vdc.v`, `pce_vce.v`, `pce_psg.v`

- **HuC6280:** passes the full 65C02 single-step suite, plus a test card for Hudson's own
  instructions, the MMU, the timer and the interrupts.
- **HuC6270 VDC** (pixel-exact directed test), **HuC6260 VCE**, the six-channel **PSG**, and
  a two-port multitap.

### Atari 2600 — `rtl/a26_top.v`, `a26_tia.v`, `a26_riot.v`

- **6507:** the NES's 6502 with RDY.
- **TIA** and **RIOT**.
- **Bank switching:** 2K to 32K, including F8/F6/F4, Super Chip, FE, E0, 3F and FA. A scheme
  named in the file name wins.

### Super NES — `rtl/snes_top.v`, `w65816.v`, `snes_cpu.v`, `snes_ppu.v`, `snes_apu.v`, `spc700.v`, `snes_dsp.v`

- **65816 and SPC700:** bus-cycle exact against over 750,000 recorded SingleStepTests cases.
  gilyon's CPU and SPC test ROMs pass on the board.
- **PPU:** modes 0-7. Hi-res modes are shown 256 wide.
- **DSP:** eight voices, echo and the Gaussian filter.
- **Cartridges:** LoROM and HiROM up to 6 MB. No enhancement chips.

### Nintendo 64 — `rtl/n64_top.v`, `vr4300.v`, `vr4300_fpu.v`, `n64_rsp.v`, `n64_rdp*.v`, `n64_vid.v`

Covered in [N64.md](N64.md).

### DOS PC — `rtl/pc_top.v`, `pc_*.v`, `rtl/pc/` (third-party)

The one machine **not** written from scratch for this project. It is nand2mario's 486Tang (a
port of ao486_MiSTer: Aleksander Osman's ao486 CPU and chipset), with MiSTer's L2 cache, IDE
code and Sound Blaster, and Greg Taylor's OPL3. Every part's licence is listed in
[THIRD_PARTY.md](THIRD_PARTY.md). Our own parts:

- **`pc_top.v`:** the system (CPU, L2 cache, chipset, VGA, sound, IDE) on the console's DDR3
  (`pc_ddr64.v`), at 71.4 MHz.
- **`pc_fb.v`:** the VGA's picture out of DDR3, scaled to 640 x 480. VESA SVGA modes (8-bit
  through the palette, 16-bit RGB565) come from the framebuffer the L2 cache writes.
- **`pc_disk.v`:** the IDE hard disk, served by the ESP32 from an image on the SD card, with
  read-ahead.
- **CD-ROM:** an ATAPI drive on the second IDE channel. The ESP32 serves its sectors from a
  `.cue` / `.bin` image (`esp32/console/cdrom.h`, a port of MiSTer's CD-ROM code). CD audio
  plays through `pc_cdda.v`.
- **Mouse and keyboard:** the pad, mapped per game (`esp32/console/pc.h`).
- **The BIOS load** (`pc_ddr64.v`): the ESP32's words gathered four to a DDR3 line behind a queue,
  so none is lost when DDR3 is slow; a lost word would raise ctrl `0x706C`.

### PlayStation — `rtl/ps1_*.v`, `r3000.v`

The largest machine by far. The next section covers it.

## The PlayStation in depth

```
                +---------+     +-------+    +-------+     +-----------+
  pad + card -->|  SIO0   |     |  GTE  |<-->| R3000 |<--->| I-cache 4K |
                +---------+     +-------+    +-------+     | D-cache 4K |
                +---------+                      |         +-----------+
  CD sectors -->| CD-ROM  |--+                   v               |
  (PC or ESP32) +---------+  |   +-----+   +-----------+   +-------------+
                             +-->| DMA |-->| 64 kB L2  |-->|             |
                +---------+  |   +-----+   | (BRAM)    |   |  memory     |
                |   GPU   |<-+       |     +-----------+   |  arbiter    |---> DDR3
                | raster  |<---------+                     |  (6 ports)  |
                | 2 px/clk|--> VRAM cache, block writer -->|             |
                +---------+                                |             |
                | scanout |--> frame stream -> Ethernet    |             |
                +---------+                                |             |
                +---------+                                |             |
                |   SPU   |--> sound ring -> Ethernet      |             |
                +---------+--------------------------------+-------------+
```

### Memory

The PlayStation's memories all live in DDR3, behind a six-port arbiter
(`mem_arb.v`) that speaks in 16-byte lines:

| DDR3 address | What |
|---|---|
| 0 MB | VRAM, 1 MB |
| 1 MB | main RAM, 2 MB |
| 3 MB | BIOS, 512 kB (loaded by the PC) |
| 4 MB | the frame capture area |
| 8 MB | SPU RAM, 512 kB (the top 128 kB is mirrored in block RAM, for reverb) |
| 9 MB | the memory cards, 128 kB each (card 2 at +128 kB) |

DDR3 answers in tens of clocks, so everything that runs often has a cache in
front of it. Most of the performance work in this project went into those
caches.

### The CPU — `r3000.v`, `ps1_icache.v`, `ps1_cache.v`

A MIPS I R3000A as the console has it:
- no TLB and no FPU, with load delay slots and branch delay slots;
- COP0 exceptions and interrupts, and COP2 for the GTE.

The register file sits in LUT-RAM.

**The cache hierarchy:**
- **L1:** a 4 kB instruction cache and a 4 kB data cache, both answering in
  the same cycle. The real console has no data cache, only a scratchpad, so the
  data cache is a speed aid rather than hardware accuracy.
- **Store buffer:** stores go through it.
- **L2:** a 64 kB write-back cache in block RAM, backed by DDR3.

**The clock.** The real R3000 runs at 33.8688 MHz. Here the CPU runs on every
50 MHz clock by default, while the timers, the video and the sound keep the
console's own 33.8688 MHz. This makes up for the CPU spending three clocks on a
load where the real one spends one. Without it, Crash's levels ran at 20 frames
a second where the console runs them at 30. Control register 0xEC bit 12
restores strict console pace.

### The GTE — `ps1_gte.v`

The geometry coprocessor handles perspective transformation, lighting and depth
cueing, with the real chip's flags, saturation and division.
- It was checked against a Python model, then against vectors recorded on real
  hardware ([ps1-tests](https://github.com/JaCzekanski/ps1-tests)).
- Those vectors found three faults the model could not.

### The GPU — `ps1_gpu.v`, `ps1_raster.v`, `ps1_gpu_blk.v`, `ps1_vram_port.v`

**Command processing:** the GP0/GP1 command set, polygons, lines and
rectangles, VRAM transfers and fills, and the display registers.

**The rasteriser** is a pipeline that draws two pixels a clock.
- It covers flat, Gouraud and textured fills, all texture depths, semi-
  transparency modes and dithering.
- Its edges are computed incrementally, not multiplied per pixel.

**Textures** come through a small cache that fetches a 2D tile on a miss,
because a span walks down the texture as well as across it. Palettes (CLUTs)
have a cache of their own.

**Writes** go to VRAM through a block writer. It posts whole 16-byte lines
with a byte mask, straight to the arbiter, so drawing does not wait on
read-modify-write cycles.

**The scanout** reads the displayed buffer out of VRAM at the game's resolution
(256 to 640 wide, including interlaced 480-line modes). It streams the frame to
the network whenever the game flips buffers.

### The SPU — `ps1_spu.v`, `ps1_spu_gauss.v`, `ps1_spu_ram.v`

The whole sound processor:
- 24 ADPCM voices with Gaussian interpolation, the full ADSR envelope, pitch
  modulation and the noise generator;
- the 39-tap reverb, SPU RAM transfers, and the IRQ;
- CD audio into the mix and the reverb, at the CD volume;
- the four capture buffers (CD left and right, voices 1 and 3), which raise
  the IRQ like any other SPU RAM address.

`tools/ps1/spu_ref.py` is a Python model built from DuckStation and psx-spx. The
testbench checks the hardware against it bit for bit. On the board, the boot
chime and Crash's music match DuckStation's output (a spectral correlation of
0.98 and 0.993).

### The CD-ROM — `ps1_cdrom.v`, `host_cd.v`, `cd_feed.v`

**The drive controller:**
- the command set with its INT1–INT5 responses;
- seeking, and reading at single and double speed, with the right timing;
- raw 2352-byte sectors into an 8-sector ring;
- DMA channel 3;
- a table of contents (up to 99 tracks), loaded by the PC;
- CD audio: Play, report mode, auto-pause, GetTN, GetTD, GetlocP, Mute and the
  volume matrix;
- XA-ADPCM: the filter, and the interleaved channels.

**CD audio** goes through the same ring as data. An audio sector is 588 stereo
samples, and the drive plays them at 44.1 kHz. An audio CD answers GetID as one,
and the BIOS opens its CD player.

**XA** is decoded on the PC. The drive queues each XA sector that passes the
game's filter. The server reads it from the disc and decodes and resamples it,
exactly as DuckStation does (`tools/ps1/cdaudio.py`). It sends the samples back into a
4096-sample buffer on the board. So XA plays only from a disc served by the PC.

With no disc it reports lid open and motor off, as DuckStation's drive does,
and the BIOS shows its menu.

**The sectors** come from one of two places:
- **The PC over Ethernet** (`host_cd.v`). The server reads the disc and writes
  each sector into a window, with its block number. The disc can be a `.bin`,
  or a `.cue` whose tracks are `.bin`, WAV, MP3, FLAC or OGG files. An audio
  file is decoded once to CD audio and kept in `build/cdda_cache/`.
- **The ESP32's SD card** (`cd_feed.v`, over SPI). The ESP32 reads ahead on one
  core and sends on the other, so it delivers sectors faster than a real
  double-speed drive. When it read and sent one after the other, it was slower
  than a real drive, and Crash crashed in its intro with the fast CPU.

### The memory cards and pads — `ps1_sio.v`

Each of the two slots holds a memory card and a digital pad with all sixteen
buttons. The cards answer the read, write and get-ID commands byte for byte as
DuckStation's do.
- **Storage:** the card's 128 kB live in DDR3.
- **Loading:** the server loads two `.mcr` files there along with the BIOS.
  This is the raw format DuckStation and most card tools use.
- **Saving:** every sector a game writes is queued on the board, and the server
  copies it back into the file within a fraction of a second. The file stays
  current even if the power goes.
- **Checked:** in simulation, and on the board with Crash's load screen and the
  BIOS's own card manager. Slot 2's pad and card are checked on the board by
  `tools/ps1/ps1slot2test.py`.

### The rest

- **DMA:** channels for the GPU, the CD, the SPU and the ordering table.
- **Timers**, the interrupt controller, and the scratchpad.

A frame-event profiler records flips, display-list DMA and GPU idle times,
readable from the PC (`tools/ps1/ps1frameevents.py`).
