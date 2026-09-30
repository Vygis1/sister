# fpga-console

Four game consoles in Verilog on an inexpensive Artix-7 board: **NES**, **Sega Master
System**, **Sega Mega Drive** and **Sony PlayStation**. One console per
bitstream, switched from a web page; the picture, the sound and the controller
travel over Ethernet to a browser on your PC.

Every CPU, video chip and sound chip here was written for this project, and
each is checked against a reference: Klaus Dormann's 6502 functional test and
the nestest log, ZEXDOC/ZEXALL for the Z80, instruction sweeps for the 68000
and the R3000, and the SPU bit-exact against a model built from DuckStation and
psx-spx.

| Console | CPU | What works |
|---|---|---|
| NES | cycle-accurate 6502 | PPU, APU, mappers 0 (NROM) and 4 (MMC3) |
| Master System | Z80 | VDP, SN76489, Sega mapper |
| Mega Drive | 68000 + Z80 | VDP with DMA, YM2612, SN76489; cartridges in DDR3 |
| PlayStation | R3000A + GTE | GPU, SPU (24 voices, reverb), CD-ROM, DMA, timers, pad, memory card |

The PlayStation boots the real BIOS and runs Crash Bandicoot at 30 fps in its
levels. Its CPU runs on every 50 MHz clock by default, to make up for taking
more clocks per load than the real chip. The timers, video and sound keep the
console's own 33.8688 MHz, so games keep their pace. Not done yet: CD audio
(CD-DA and XA) and the SPU's capture buffers. [docs/PLAYSTATION.md](docs/PLAYSTATION.md)
has the details.

## What you need

- **QMTECH Artix-7 XC7A100T core board** (xc7a100tfgg676-1, 256 MB DDR3).
  [docs/BOARD.md](docs/BOARD.md) covers board facts, the flash part and the
  JTAG programmer.
- **A LAN8720 RMII Ethernet module** on header U4. The pinout, and the power pins
  not to use, are in [boards/qmtech_a100t/lan8720.xdc](boards/qmtech_a100t/lan8720.xdc).
- **A JTAG cable** for the first load: Xilinx Platform Cable, Digilent, or an
  FT2232H with openFPGALoader.
- **Vivado 2026.1**, the free edition; no licence is needed for this part.
- **Python 3.10+** with Flask (`pip install -r requirements.txt`).
- Optional: an **ESP32-S3** with a microSD card as a stand-alone front door
  ([esp32/README.md](esp32/README.md)).

**Games and BIOS are not included and never will be.** Use dumps of cartridges
and discs you own, and for the PlayStation a dump of your own console's BIOS
(e.g. SCPH-1001).

## Quick start

Run everything from Git Bash on Windows, or from a shell on Linux, at the
repository root.

```sh
./tools/vivado.sh check          # is the toolchain usable for this part?
./tools/vivado.sh mig            # once: generate the DDR3 controller (Mega Drive, PlayStation)
EFFORT=1 ./tools/core.sh ps1     # or nes / sms / md / shell; ~35 min for ps1 -> cores/ps1.bin
./tools/core.sh shell            # the golden image: it installs and switches cores
```

Put the shell in the board's configuration flash once over JTAG. The
[docs/BOARD.md](docs/BOARD.md) section on flashing has the exact part name to
use. From then on, cores are installed from the web page.

```sh
pip install -r requirements.txt
cp local.env.example local.env   # this machine's settings: board address, BIOS path, card file
python pc/server.py --target 192.168.178.50
# then open http://127.0.0.1:8080
```

The board's address is set in the bitstream, in `rtl/eth_top.v` (`IP_ADDR`,
192.168.178.50 by default). If you change it there to suit your network, set
`FPGA_HOST` in `local.env` to match, for the server and the tools in `tools/`.
Any setting in `local.env` can also be given as an environment variable.

### Playing

Drop a game on the page, or pick one with the Slot panel. The keyboard
defaults are the arrow keys, Z / X (A and B, or Cross and Circle), A / S
(Square and Triangle), Q / W (L1 and R1), 1 / 2 (L2 and R2), Shift for Select
and Enter for Start. Any gamepad works as well. **Remap…** in the Controls
panel changes any binding, and the choice is kept in the browser.

### PlayStation specifics

- **BIOS:** upload it on the page, or set `PS1_BIOS` in `local.env` so the
  server puts it back whenever the console is reset.
- **Disc:** a raw MODE2/2352 `.bin`. The server feeds it to the board over
  Ethernet (`/api/disc/select`, then `/api/disc/host`), or the ESP32 reads it
  from its SD card.
- **Memory card:** `saves/card1.mcr` (or `PS1_CARD`). It is a raw 128 kB card,
  the format DuckStation uses, created blank if it does not exist. It is loaded
  with the BIOS, and every sector the game writes is copied back to the file
  within a fraction of a second. A `.bak` of the file as it was is kept at the
  first load of each session.

## How it fits together

    browser  <--HTTP-->  pc/server.py  <--UDP (fpgalink)-->  FPGA  <--SPI-->  ESP32 (optional)
                                        <--UDP frames/audio--

- **fpgalink** is a register bus over UDP with no CPU in the path
  ([docs/PROTOCOL.md](docs/PROTOCOL.md)). Everything the page does is register
  reads and writes.
- **The shell** is the golden image at flash address 0. It writes cores into the
  slot and reboots into them, and a power cycle always brings it back, so a bad
  core cannot brick the board ([docs/SHELL.md](docs/SHELL.md)).
- **The video** is pushed by the board as UDP packets, one captured frame at a
  time, and the page draws it on a canvas. **The sound** is a ring buffer the
  server drains.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) covers where everything lives.
  [docs/MEGADRIVE.md](docs/MEGADRIVE.md),
  [docs/Z80-DESIGN.md](docs/Z80-DESIGN.md) and
  [docs/ROADMAP.md](docs/ROADMAP.md) record how each part was built and what
  went wrong on the way.

## Layout

    rtl/        the consoles and the board infrastructure (Ethernet, DDR3, shell)
    sim/        testbenches; ./tools/sim.sh <bench> runs one under Vivado's xsim
    pc/         server.py (web UI backend), fpgalink.py (the bus), mock_fpga.py
    web/        the page
    tools/      build, flash, simulation and board-debugging scripts
    boards/     constraints for the QMTECH board and its add-ons
    esp32/      the ESP32-S3 front door (Arduino sketch)
    docs/       design notes

## Tests

```sh
./tools/simps1.sh     # the PlayStation gate: caches, SPU, pad and memory card, GPU, CPU, BIOS boot
./tools/simall.sh     # the other cores
```

Several benches need files that cannot be redistributed, or that come from
other projects, placed in `sim/roms/`:
- a PlayStation BIOS, and commercial cartridges for the game-level benches;
- Klaus Dormann's 6502 functional test (GPL-3), ZEXDOC/ZEXALL (GPL-2),
  nestest and blargg's NES tests.

Each bench says which file it wants and where.

## Releases

`VERSION` holds the release number and `CHANGELOG.md` says what is in it.
`./tools/release.sh` packages a release into `dist/`: the five core images, the
ESP32 firmware, the source of the commit, and SHA-256 checksums. It refuses to
run with uncommitted changes, or with an image older than the RTL.

## Security

`pc/server.py` listens on 127.0.0.1 by default, and it should stay that way. It
can read any file the disc and card routes are pointed at, and it has no
authentication. Do not expose it beyond a network you trust.
