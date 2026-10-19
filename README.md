<div align="center">

# FPGA Console

**Twelve classic game systems and a DOS PC, implemented in hardware on a single low-cost FPGA board.**

HDMI out · Bluetooth controllers · Games from an SD card · No emulation, no operating system

![Platform](https://img.shields.io/badge/FPGA-Artix--7%20XC7A100T-blue)
![HDL](https://img.shields.io/badge/HDL-Verilog-informational)
![Systems](https://img.shields.io/badge/systems-13-success)
![Testbenches](https://img.shields.io/badge/testbenches-139-success)

<img src="docs/images/screens/grid.png" width="780" alt="Frames captured from the board: Super Mario Bros. (NES), Super Mario World (SNES), Super Mario 64 (N64), Combat Cars (Mega Drive), MediEvil (PlayStation), Quake (DOS PC), cgb-acid2 (Game Boy Color), Tonc Mode 7 demo (GBA), PCE_Blox (PC Engine)">

<sub>Every frame above was captured from the running board: Super Mario Bros., Super Mario World, Super Mario 64, Combat Cars, MediEvil, Quake, cgb-acid2, Tonc's Mode 7 demo, PCE_Blox.</sub>

</div>

---

## Overview

Each system is a hardware design: its processors, graphics and sound chips run as logic inside the
FPGA, clock by clock, as the original chips did. A small resident image (the *shell*) loads
the chosen console into the FPGA, and an ESP32 runs the on-screen menu, streams games from the SD
card and connects Bluetooth controllers.

- **One console at a time, the whole chip for it.** Choosing a game for another system loads that
  system's FPGA image.
- **Verified against references, not by eye.** CPU cores are checked against instruction-level test
  suites; graphics and sound against bit-exact models and recordings from real hardware.
- **Off-the-shelf parts.** An Artix-7 core board, an HDMI breakout and an ESP32 board.

## Systems

| System | Status | Notes |
|---|:---:|---|
| Nintendo Entertainment System | ✅ | Mappers 0-4, 7 (NROM, MMC1, UxROM, CNROM, MMC3, AxROM) |
| Sega Master System | ✅ | |
| Sega Game Gear | ✅ | 12-bit palette, stereo |
| Nintendo Game Boy / Color | ✅ | MBC1/3/5; cgb-acid2 pixel-exact on hardware |
| Nintendo Game Boy Advance | ✅ | Open BIOS built in; cartridge clock (RTC) |
| Atari 2600 | ✅ | Bank switching 2K-32K |
| Sega Mega Drive / Genesis | ✅ | Cartridges up to 4 MB, stereo FM |
| Super Nintendo | ✅ | LoROM/HiROM, save RAM; no enhancement chips yet |
| NEC PC Engine / TurboGrafx-16 | ✅ | HuCards; no CD-ROM |
| Sony PlayStation | ✅ | Real BIOS; disc images, memory cards, CD audio, XA, FMV |
| Nintendo 64 | 🟡 | Super Mario 64 and Mario Kart 64 at close to full speed; some RDP modes missing |
| DOS PC (486) | 🟡 | 486 + x87 FPU, SVGA, Sound Blaster 16, CD-ROM; Doom, Quake. CPU being sped up |

✅ plays well · 🟡 works, with known gaps — see [docs/ROADMAP.md](docs/ROADMAP.md)

Per-system details: [docs/CONSOLES.md](docs/CONSOLES.md).

## Hardware

| Part | Purpose |
|---|---|
| [QMTECH Artix-7 XC7A100T core board](docs/BOARD.md) (256 MB DDR3, 8 MB flash) | The consoles |
| HDMI breakout on header U4 | Video and audio to the TV (640×480, 48 / 44.1 kHz) |
| LilyGO T8 (ESP32-WROVER) with microSD | Menu, game loading, Bluetooth controllers |

Controllers: PlayStation 4/5, Xbox and Switch Pro over Bluetooth.

## Getting started

1. **Wire it up**: HDMI breakout and six (or eight) wires to the ESP32.
2. **Program the shell** into the FPGA's flash over JTAG, once.
3. **Flash the ESP32** firmware.
4. **Prepare the SD card**: cores in `/cores`, games in `/roms/<system>`.
5. **Power on**, pair a controller, pick a game.

Step-by-step instructions are in **[docs/GUIDE.md](docs/GUIDE.md)**.

## Building from source

**Requirements:** Vivado 2026.1 · Arduino CLI with the `esp32-bluepad32` platform · Python 3.10+ ·
WSL with `mtools`, `nasm` and Verilator (DOS disk images, PC simulation)

```sh
./tools/core.sh snes                 # one system's FPGA image  ->  cores/snes.bin
./tools/core.sh pc                   # the DOS PC (ao486);  PC_Z486=1 for the z486 + FPU
RELEASE=1 ./tools/core.sh n64        # a release image, without debug hardware
./tools/sim.sh tb_line_grab          # a testbench in Vivado's simulator
```

Targets: `nes sms gg gb gba a26 md snes pce ps1 n64 pc shell`. The PlayStation and N64 fill the
device and build with `EFFORT=1 AREA=1`. ESP32 firmware: [esp32/README.md](esp32/README.md).
Tools for each system: [tools/README.md](tools/README.md).

## Repository layout

```
rtl/        Verilog: every system, plus the board (HDMI, DDR3, the ESP32 link, the shell)
rtl/pc/     the DOS PC's third-party CPU and chipset (ao486, z486, OPL3, MiSTer parts)
esp32/      ESP32 firmware: menu, loaders, Bluetooth controllers, the PC's disks
sim/        testbenches
tools/      build, simulation, reference models and board tools
boards/     pin and timing constraints for the QMTECH board
hardware/   3D-printable case and cable
docs/       guide, design notes, third-party licences
```

## Documentation

| | |
|---|---|
| [GUIDE.md](docs/GUIDE.md) | Building and using the console |
| [CONSOLES.md](docs/CONSOLES.md) | How each system is built and verified |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Shell, slots, memory map, the ESP32 link |
| [PLAYSTATION.md](docs/PLAYSTATION.md) · [N64.md](docs/N64.md) · [MEGADRIVE.md](docs/MEGADRIVE.md) | System deep dives |
| [DEVELOPMENT.md](docs/DEVELOPMENT.md) | Debugging on the board, simulation |
| [THIRD_PARTY.md](docs/THIRD_PARTY.md) | Third-party components and their licences |

## Verification

- **CPUs:** the SingleStepTests suites (65816, SPC700, SM83, 65C02, ARM7TDMI), Klaus Dormann's 6502
  test and nestest, ZEXDOC/ZEXALL, blargg's Game Boy tests, krom's N64 CPU/RSP/RDP tests, a
  2,500-case R3000 program.
- **Graphics and sound:** GTE results recorded on a PlayStation; bit-exact models of the
  PlayStation SPU and the N64 RSP/RDP; dmg-acid2 and cgb-acid2; reference renderers for the GBA
  and PC Engine.
- **On the board:** every system checked by picture after each change
  (`tools/coreshots.py`, `tools/vgrab.py`).

## Acknowledgements

The DOS PC is built on [ao486](https://github.com/alfikpl/ao486) by Aleksander Osman,
[486Tang](https://github.com/nand2mario/486tang) and [z486](https://github.com/nand2mario/z486)
by nand2mario, MiSTer's ao486 cache and IDE code, and Greg Taylor's OPL3. The Game Boy Advance
uses the [Cult-of-GBA](https://github.com/Cult-of-GBA/BIOS) open BIOS. Full list with licences:
[docs/THIRD_PARTY.md](docs/THIRD_PARTY.md).

## License

Not yet chosen; until a `LICENSE` file is added, all rights are reserved. Third-party components
keep their own licences.

**No games, BIOS images or other copyrighted data are included.** Use your own dumps. All product
names are trademarks of their respective owners; this project is not affiliated with any of them.
