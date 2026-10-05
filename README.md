# fpga-console

> **The stand-alone console** -- HDMI to the TV, a menu on the screen, games on an SD
> card, Bluetooth pads, no PC: [docs/GUIDE.md](docs/GUIDE.md) has the parts, the wiring,
> the first programming and how to play. The rest of this page describes the
> development setup (the web page over Ethernet), which still works.

Five game consoles written in Verilog, running on an inexpensive Artix-7
board: the **NES**, the **Sega Master System**, the **Sega Mega Drive**, the
**Sony PlayStation** and the **Nintendo 64**. The board becomes whichever one you choose. The
picture, the sound and the controller travel over Ethernet to a web page on
your PC, and a small ESP32 on the side can run the board without a PC at all.

Nothing is emulated in software. Each CPU, video chip and sound chip is written
for this project as hardware, and each is checked against an independent
reference:
- **CPUs:** Klaus Dormann's 6502 test and the nestest log, ZEXDOC and ZEXALL
  for the Z80, a self-checking test program for the 68000, and a generated
  instruction sweep for the R3000;
- **PlayStation GTE:** test vectors recorded on a real PlayStation;
- **PlayStation SPU:** a bit-exact model built from DuckStation and psx-spx.

The PlayStation boots the real BIOS, plays Crash Bandicoot at 30 frames a
second, saves to two memory cards, and reads its disc from the PC or from an SD
card. It plays CD audio and XA, and a disc's audio tracks can be MP3 files.

- [What it is](#what-it-is)
- [Hardware](#hardware)
- [How it fits together](#how-it-fits-together)
- [The consoles](#the-consoles)
- [The PlayStation in depth](#the-playstation-in-depth)
- [The infrastructure](#the-infrastructure)
- [Getting started](#getting-started)
- [Using it](#using-it)
- [Development](#development)
- [Repository layout](#repository-layout)
- [Status and known issues](#status-and-known-issues)
- [Documentation](#documentation)
- [Legal](#legal)

---

## What it is

**One console per image.** Each machine is built as its own bitstream, so it
gets the whole chip. A small permanent image, **the shell**, lives at the start
of the board's configuration flash. It writes a console into the flash, starts
it, and comes back at power-up if a console ever misbehaves. Switching machines
takes one click on the page; the board rewrites itself and reboots in a minute
or two.

**The screen is your browser.** The board has no video connector in use. The
page shows the picture on a canvas and plays the sound through the browser.
- The board pushes each finished frame to the PC as UDP packets, and a Python
  server hands frames and sound to the page.
- Keyboard and gamepad presses go back the same way, as one register write
  each.

**The PC does the heavy lifting only where it helps:**
- it holds the game files and serves the PlayStation's CD image sector by
  sector;
- it keeps the memory card file;
- it reprograms the board when you switch machines.

The consoles themselves run entirely in the FPGA.

---

## Hardware

| Part | What it does |
|---|---|
| **QMTECH Artix-7 XC7A100T core board** (xc7a100tfgg676-1, 256 MB DDR3, 8 MB SPI flash) | Everything. [docs/BOARD.md](docs/BOARD.md) has the board's facts, pinouts and flash part. |
| **LAN8720 RMII Ethernet module** on header U4 | The link to the PC. The pinout, and which power pins not to use, are in [lan8720.xdc](boards/qmtech_a100t/lan8720.xdc). |
| **JTAG cable** (Xilinx, Digilent, or an FT2232H with openFPGALoader) | The first programming of the shell, and core installs from the PC. |
| **ESP32-S3** with a microSD card, on header U2 (optional) | A stand-alone front door: a phone-sized web page, a library of cores on the SD card, the PlayStation's disc served from the SD card, and the wire that forces the board back to the shell. See [esp32/README.md](esp32/README.md). |

The FPGA fabric: 63,400 LUTs, 135 block RAMs (36 kb each), 240 DSP slices.
The PlayStation uses about 51,000 of the LUTs and 107 of the block RAMs, and it
meets timing at 50 MHz with a few hundred picoseconds to spare. It is the
largest design this chip will comfortably hold.

---

## How it fits together

```
                 Ethernet (UDP)                                     SPI
  browser  <--HTTP-->  pc/server.py  <------------------->  FPGA  <--------->  ESP32-S3
  (web/)               Python, Flask   fpgalink: registers   |                 SD card:
                                       frames:  board -> PC  |                 cores, discs
                                                             |
                                                           DDR3 (256 MB):
                                                           cartridges, VRAM, RAM,
                                                           BIOS, SPU RAM, memory card
```

**fpgalink**, the register bus. Everything the PC does to the board is a read
or a write of a 32-bit register at a 32-bit address, carried in UDP datagrams
to port 5005.
- The FPGA parses the packet with a counter and a shift register. There is no
  processor on the board's side of the link.
- The protocol is in [docs/PROTOCOL.md](docs/PROTOCOL.md): a 12-byte header, and
  opcodes READ, WRITE, READ_BLOCK and IDENT.
- Uploading a game, pressing a button, reading the sound ring and debugging the
  CPU all use this one mechanism.

**The picture** goes the other way, unasked.
- When a frame is finished, the board streams it to the PC as UDP packets of up
  to 350 words (port 5006). Each packet carries a frame id and a word offset, so
  the PC reassembles frames regardless of order and drops any that arrive
  incomplete.
- The server keeps the newest complete frame. The page pulls it over HTTP and
  paints it: RGB332 for the NES, Master System and Mega Drive, and 15-bit colour
  at the game's own resolution for the PlayStation.
- The browser receives about 30–38 frames a second.

**The sound** is a ring buffer on the board: mono at 48.8 kHz for the first
three consoles, stereo at 44.1 kHz for the PlayStation.
- A thread in the server reads the new samples every few milliseconds.
- The page plays them through Web Audio about 70 ms behind real time.

---

## The consoles

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
  (`tools/m68kasm.py`), which covers results, condition codes and addressing
  modes separately.
- **VDP:** planes, sprites and all three DMA modes.
- **Z80 sound CPU:** with its bus handover and bank register.
- **Sound chips:** the SN76489, and a YM2612 FM chip computed in decibels, as
  the real chip is.
- **Cartridges** are read from DDR3 through a cache, so games of up to 4 MB fit.

### PlayStation — `rtl/ps1_*.v`, `r3000.v`

The largest machine by far. The next section covers it.

---

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

`tools/spu_ref.py` is a Python model built from DuckStation and psx-spx. The
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
exactly as DuckStation does (`pc/cdaudio.py`). It sends the samples back into a
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
  `tools/ps1slot2test.py`.

### The rest

- **DMA:** channels for the GPU, the CD, the SPU and the ordering table.
- **Timers**, the interrupt controller, and the scratchpad.

A frame-event profiler records flips, display-list DMA and GPU idle times,
readable from the PC (`tools/ps1frameevents.py`).

---

## The infrastructure

**`eth_top.v`, `net_core.v`, `rmii_rx/tx.v`:** a complete Ethernet endpoint in
hardware.
- RMII to the LAN8720, and ARP.
- The fpgalink packet engine, and the frame streamer.
- It all runs in the PHY's own 50 MHz clock domain, so there is no clock
  crossing anywhere in the data path.

**`regfile.v`, `console_top.v`:** the register map. They choose which console
is built into an image and wire its video, audio and controls to the network.
They also carry the developer tools, available to every core:
- a 32-channel logic analyser;
- an eight-voice test synthesiser;
- MDIO access to the PHY.

**`shell_top.v`, `spi_flash.v`, `esp_link.v`:** the golden image: about 5,700
LUTs and 3.5 block RAMs, 9% of the chip.
- It erases and programs the configuration flash, and restarts the FPGA into a
  core slot through ICAPE2 (WBSTAR and IPROG).
- It cannot overwrite itself, because a slot address and an offset are
  concatenated rather than added.
- Configuration fallback returns to it if a slot fails to load.

**`pc/server.py`:** the PC side, a single Flask application.
- It serves the page, and relays the picture, the sound and the pad.
- It loads cartridges and the BIOS, and serves the PlayStation's disc (the
  HostDisc thread).
- It keeps the memory card file (the MemCard thread).
- It installs cores over JTAG, restores the PlayStation BIOS after a reset, and
  talks to the ESP32.

**`web/`:** the page. It is plain HTML and JavaScript with no build step.

**`esp32/console/`:** the ESP32-S3 firmware (Arduino). It is a phone-sized
page on its own Wi-Fi access point, or on your network.
- It shows what the board is, installs cores from the SD card, and joins Wi-Fi.
- It shows and changes the PlayStation's disc.
- It can pull PROGRAM_B to force the board back to the shell.

---

## Getting started

Developed and tested on Windows with Git Bash. The scripts are plain bash and
Python and use nothing Windows-specific in the build path, but Linux has not
been tried.

### 1. Toolchain

- **Vivado 2026.1**, the free edition; the XC7A100T needs no licence. The
  scripts look for it under `C:\AMDDesignTools` and `C:\Xilinx`; set
  `VIVADO_BIN` to point elsewhere.
- **Python 3.10 or newer**: `pip install -r requirements.txt` (Flask).
- **For the ESP32**, arduino-cli with the esp32 core. The build line is in
  [esp32/README.md](esp32/README.md).

```sh
./tools/vivado.sh check          # is the toolchain usable for this part?
```

### 2. Build

```sh
./tools/vivado.sh mig            # once: generate the DDR3 controller (Mega Drive, PlayStation)
./tools/core.sh shell            # the golden image
./tools/core.sh nes              # and any of: nes sms md
EFFORT=1 ./tools/core.sh ps1     # the PlayStation, with timing-driven place and route (~35 min)
```

Each command writes `cores/<name>.bin`, a raw image for a flash slot. A build
that misses timing is refused; one that passes by less than 0.08 ns is not
worth flashing.

### 3. Put the shell on the board

Write the shell to flash address 0 once, over JTAG. The exact flash part name
to give Vivado is in [docs/BOARD.md](docs/BOARD.md). From then on the board
boots into the shell, and the page installs consoles.

### 4. Run the server

```sh
pip install -r requirements.txt
cp local.env.example local.env   # this machine's settings: board address, BIOS path, card file
python pc/server.py --target 192.168.178.50
# open http://127.0.0.1:8080
```

The board's IP address is set in the bitstream (`IP_ADDR` in `rtl/eth_top.v`,
192.168.178.50 by default). To use another address, change it there, rebuild,
and set `FPGA_HOST` in `local.env`.

| `local.env` setting | Meaning |
|---|---|
| `FPGA_HOST` | the board's address, for the server and every tool |
| `PS1_BIOS` | your PlayStation BIOS dump; the server restores it after every console reset |
| `PS1_CARD` | memory card 1 (default `saves/card1.mcr`, created blank if missing) |
| `PS1_CARD2` | memory card 2 (default `saves/card2.mcr`) |
| `ESP_HOST` | the ESP32's address, if you have one |

---

## Using it

**Switching machines.** Pick one under System. The board rewrites its flash
over JTAG and restarts into the machine you chose, which takes a minute or
two.

**Loading a game.** Drop a file anywhere on the page, or use the Slot panel.
The file itself says what it is: an iNES header means the NES, "SEGA" at $100
means the Mega Drive, anything else a Master System cartridge. On the
PlayStation, a headerless 512 kB file is taken as the BIOS.

**The PlayStation's panel** shows:
- the BIOS;
- the disc, which you can switch between this PC and the SD card;
- both memory cards, and how many sectors each has saved.

The disc is a raw MODE2/2352 `.bin`, or a `.cue` sheet. Select one on the PC
with `/api/disc/select`, or pick one on the ESP32's page. A `.bin` with a
`.cue` of the same name beside it is opened through the cue, so its audio
tracks come with it. The ESP32 serves a single `.bin` only: it has no table of
contents to give the drive, and no XA.

**Audio tracks from MP3.** Most rips keep the music as one file per track. A
cue like this works as it is:

```
FILE "game.bin" BINARY
  TRACK 01 MODE2/2352
    INDEX 01 00:00:00
FILE "track02.mp3" MP3
  TRACK 02 AUDIO
    INDEX 01 00:00:00
```

The first time a track is played it is decoded in the background (a second or
two for a four-minute MP3). This needs `miniaudio` (`pip install -r
requirements.txt`).

**Controls.**

| Key | Button |
|---|---|
| Arrow keys | D-pad |
| Z | A, or Cross |
| X | B, or Circle |
| A | Square |
| S | Triangle |
| Q / W | L1 / R1 |
| 1 / 2 | L2 / R2 |
| Shift | Select |
| Enter | Start |

Any gamepad works too, using the standard layout. Remap… changes any binding,
and the choice is kept in the browser. A second gamepad is player 2. The page names buttons the way each
machine does.

**Developer view.** The Developer button in the header opens the tools:
- the logic analyser;
- the test synthesiser, with a keyboard, a scope and WAV recording;
- the Ethernet PHY's registers;
- raw register peeks and pokes, and a bus self-test.

---

## Development

**Simulation** uses Vivado's xsim:

```sh
./tools/sim.sh tb_ps1_mcard      # one testbench
./tools/simps1.sh                # the PlayStation gate: caches, SPU, pad and card, CD, GPU, GTE, CPU, BIOS boot
./tools/simall.sh                # the other machines
```

The PlayStation gate runs the real BIOS in simulation. It needs a BIOS image
in `sim/roms/`, as do the benches that run commercial games. Freely available
test programs are also expected there: Klaus Dormann's 6502 test (GPL-3),
ZEXDOC/ZEXALL (GPL-2), nestest and blargg's NES tests. Each bench names the
file it needs.

**On the board**, `tools/` holds the measuring and debugging scripts used to
build all this. Each script's own docstring explains it. For example:
- `ps1frameevents.py`: where a PlayStation frame's time goes.
- `ps1status.py`: CPU, GPU and DMA state.
- `ps1pace.py`: CPU and GPU pace.
- `ps1flash.py`: install, boot and load the BIOS in one step.
- `mktestdisc.py`: test discs of known tones (an MP3+WAV audio CD, and an XA
  disc with eight channels), with `xaenc.py`, a small XA encoder.
- `ps1cdtest.py`: XA and an MP3 audio track on the board, checked by frequency.
- `ps1slot2test.py`: the second pad and memory card on the board.
- `esp.py`: the ESP32's serial console.

**Releases.** `VERSION` holds the release number and `CHANGELOG.md` says what
is in it. `./tools/release.sh` packages `dist/fpga-console-<version>/`:
- the five core images and the ESP32 firmware;
- a source archive of the commit, and SHA-256 checksums.

It refuses to run with uncommitted changes, or with an image older than the
RTL.

---

## Repository layout

```
rtl/        the consoles and the board infrastructure
  cpu6502 ppu apu mapper nes          NES
  z80 vdp psg sms                     Master System
  m68k md_vdp md_sound ym2612 md_*    Mega Drive
  r3000 ps1_*                         PlayStation
  eth_top net_core rmii_* regfile     Ethernet, fpgalink, register map
  console_top                         which console an image is, and its wiring
  shell_top spi_flash esp_link        the golden image
  mem_arb ddr3_mem cart_* fb_*        DDR3, cartridges, frame capture
sim/        testbenches (tb_*.v) and simulation models
pc/         server.py, fpgalink.py (the bus), mock_fpga.py (a fake board for the page)
web/        the page
esp32/      the ESP32-S3 firmware and its wiring
tools/      build, flash, simulation, release and board-debugging scripts
boards/     constraints for the QMTECH board, the LAN8720 and DDR3
docs/       design notes, one per subsystem
saves/      memory card files (not in git)
```

---

## Status and known issues

Release **0.1.0**. [CHANGELOG.md](CHANGELOG.md) has the full list.

- **Mega Drive: no sound on the board.** The picture and the games run. The FM
  chip passes its simulation checks, but the core's audio output holds a single
  level on hardware. The fault lies in the sound driver or the FM keying, and is
  being investigated.
- **PlayStation:**
  - About one frame in ten can take 50 ms instead of 33 ms while running. The
    drawing engine is late on busy scenes.
  - XA audio plays only from a disc served by the PC, which decodes it. A disc
    on the ESP32's SD card has no XA and no audio tracks.
  - One frame of the title sequence shows a strip of junk in its top rows.
- **Video** leaves the board over Ethernet only; there is no HDMI or VGA yet.

---

## Documentation

| | |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | where everything lives: flash, SD, DDR3, block RAM |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | fpgalink, the register bus |
| [docs/SHELL.md](docs/SHELL.md) | the golden image and switching cores |
| [docs/PLAYSTATION.md](docs/PLAYSTATION.md) | the PlayStation, from the first instruction to Crash |
| [docs/MEGADRIVE.md](docs/MEGADRIVE.md) | the Mega Drive |
| [docs/Z80-DESIGN.md](docs/Z80-DESIGN.md) | the Z80 |
| [docs/ROADMAP.md](docs/ROADMAP.md) | the order things were built in, and why |
| [docs/BOARD.md](docs/BOARD.md) | the board, its flash, the programmer, the 6502 |
| [esp32/README.md](esp32/README.md) | the ESP32 front door and its wiring |

The design notes record what was tried, what was measured, and what went
wrong. Most of the interesting knowledge in the project is in them, and in the
comments above the code they describe.

---

## Legal

**No games, BIOS images or other copyrighted data are included, and none will
be.** Use dumps of cartridges and discs you own, and of your own PlayStation's
BIOS. Nintendo, Sega, Sony and PlayStation are trademarks of their owners;
this project is not affiliated with any of them.

**No licence has been chosen yet.** Until one is added, all rights are
reserved.

`pc/server.py` listens on 127.0.0.1, and it should stay there. It can read any
file its disc and card routes are pointed at, and it has no authentication. Do
not expose it beyond a network you trust.
