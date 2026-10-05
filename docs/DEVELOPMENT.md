# Development

The development setup: the board on Ethernet, `pc/server.py`, and the page in a
browser -- the picture, the sound and the pad over the network, every register
of every core readable from the PC. Everything here still works beside the
stand-alone console ([GUIDE.md](GUIDE.md)), and it is how the cores are debugged.

## Hardware

| Part | What it does |
|---|---|
| **QMTECH Artix-7 XC7A100T core board** (xc7a100tfgg676-1, 256 MB DDR3, 8 MB SPI flash) | Everything. [docs/BOARD.md](BOARD.md) has the board's facts, pinouts and flash part. |
| **LAN8720 RMII Ethernet module** on header U4 | The link to the PC. The pinout, and which power pins not to use, are in [lan8720.xdc](../boards/qmtech_a100t/lan8720.xdc). |
| **JTAG cable** (Xilinx, Digilent, or an FT2232H with openFPGALoader) | The first programming of the shell, and core installs from the PC. |
| **ESP32-S3** with a microSD card, on header U2 (optional) | A stand-alone front door: a phone-sized web page, a library of cores on the SD card, the PlayStation's disc served from the SD card, and the wire that forces the board back to the shell. See [esp32/README.md](../esp32/README.md). |

The FPGA fabric: 63,400 LUTs, 135 block RAMs (36 kb each), 240 DSP slices.
The PlayStation uses about 51,000 of the LUTs and 107 of the block RAMs, and it
meets timing at 50 MHz with a few hundred picoseconds to spare. It is the
largest design this chip will comfortably hold.

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
- The protocol is in [docs/PROTOCOL.md](PROTOCOL.md): a 12-byte header, and
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
  [esp32/README.md](../esp32/README.md).

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
to give Vivado is in [docs/BOARD.md](BOARD.md). From then on the board
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

## Working on it

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

## Documentation

| | |
|---|---|
| [docs/ARCHITECTURE.md](ARCHITECTURE.md) | where everything lives: flash, SD, DDR3, block RAM |
| [docs/PROTOCOL.md](PROTOCOL.md) | fpgalink, the register bus |
| [docs/SHELL.md](SHELL.md) | the golden image and switching cores |
| [docs/PLAYSTATION.md](PLAYSTATION.md) | the PlayStation, from the first instruction to Crash |
| [docs/MEGADRIVE.md](MEGADRIVE.md) | the Mega Drive |
| [docs/Z80-DESIGN.md](Z80-DESIGN.md) | the Z80 |
| [docs/ROADMAP.md](ROADMAP.md) | the order things were built in, and why |
| [docs/BOARD.md](BOARD.md) | the board, its flash, the programmer, the 6502 |
| [esp32/README.md](../esp32/README.md) | the ESP32 front door and its wiring |

The design notes record what was tried, what was measured, and what went
wrong. Most of the interesting knowledge in the project is in them, and in the
comments above the code they describe.
