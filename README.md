<div align="center">

# SiSTer

**Silicon Systems Together.** Twelve classic game systems and a DOS PC, rebuilt in hardware on one
inexpensive FPGA board.

Plug it into a TV, pair a controller, pick a game.

[![License: GPL v3](https://img.shields.io/badge/license-GPLv3-blue.svg)](LICENSE)
[![Ko-fi](https://img.shields.io/badge/support-Ko--fi-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/vygandasvalantiejus)

<img src="docs/images/screens/grid.png" width="760" alt="Super Mario Bros., Super Mario World, Super Mario 64, Combat Cars, MediEvil, Doom, cgb-acid2, a GBA Mode 7 demo and PCE_Blox, captured from the board">

<sub>Captured from the board's HDMI output.</sub>

</div>

## About

SiSTer turns a QMTECH Artix-7 board into a stand-alone games machine. Each system is a
hardware design: its processors, graphics and sound chips run as logic inside the FPGA, the way
the original chips did. There is no emulator and no operating system. An ESP32 next to the FPGA
runs the on-screen menu, loads games from a microSD card and connects Bluetooth controllers.

The name: **Si**licon **S**ystems **T**ogether, and a nod to [MiSTer](https://github.com/MiSTer-devel),
whose open-source work several parts of this project build on.

## Features

- **HDMI out** at 640×480 with stereo sound
- **On-screen menu** with a library view, recently played games and settings
- **Bluetooth controllers:** PlayStation 4/5, Xbox and Switch Pro
- **Games from microSD:** cartridges, PlayStation disc images and DOS hard-disk images
- **Saves on the card:** PlayStation memory cards, N64 EEPROM, SNES, Game Boy and GBA saves
- **Video options:** sharp or smooth scaling, scanlines, and the N64's own video filters
- **DOS games in one step:** `tools/pc/addgame.py` turns a game folder into a bootable disk

## Systems

| System | Status | Notes |
|---|:---:|---|
| NES | ✅ | Mappers 0, 1, 2, 3, 4, 7 |
| Master System | ✅ | |
| Game Gear | ✅ | |
| Game Boy / Game Boy Color | ✅ | MBC1, MBC3, MBC5 |
| Game Boy Advance | ✅ | Built-in open BIOS, cartridge clock |
| Atari 2600 | ✅ | Bank switching up to 32 KB |
| Mega Drive / Genesis | ✅ | Up to 4 MB |
| Super NES | ✅ | No enhancement chips yet |
| PC Engine / TurboGrafx-16 | ✅ | HuCards |
| PlayStation | ✅ | Disc images, memory cards, CD audio, FMV; needs a BIOS file |
| Nintendo 64 | 🟡 | Super Mario 64, Mario Kart 64, Super Smash Bros.; every RDP mode, other games untested |
| DOS PC | ✅ | 486 at 66.7 MHz, SVGA, Sound Blaster 16, CD-ROM. Doom, Rayman, Transport Tycoon Deluxe |

✅ playable · 🟡 partial. Details per system: [docs/CONSOLES.md](docs/CONSOLES.md) · Plans: [docs/ROADMAP.md](docs/ROADMAP.md)

## The menu

<p align="center">
  <img src="docs/images/menu_home.png" width="400" alt="Home screen">
  <img src="docs/images/menu_games.png" width="400" alt="Game list">
</p>

## Hardware

| Part | Purpose |
|---|---|
| QMTECH Artix-7 XC7A100T core board (256 MB DDR3) | Runs the systems |
| HDMI breakout board on header U4 | Video and audio |
| LilyGO T8 ESP32 board with a microSD card | Menu, games, controllers |
| JTAG programmer | One-time setup |

A 3D-printable case is in [hardware/](hardware/).

## Getting started

1. Connect the HDMI breakout and wire the ESP32 to the FPGA board.
2. Program the menu image (the *shell*) into the board's flash over JTAG.
3. Build and flash the ESP32 firmware.
4. Copy the cores and your games to the microSD card.
5. Power on, pair a controller, and pick a game.

The full walkthrough, with wiring tables, is in **[docs/GUIDE.md](docs/GUIDE.md)**.

## Building from source

You need Vivado 2026.1, the Arduino CLI with the `esp32-bluepad32` platform, and Python 3.

```sh
./tools/core.sh snes          # one system's FPGA image  ->  cores/snes.bin
./tools/core.sh shell         # the menu image
./tools/sim.sh tb_line_grab   # run a testbench
```

Systems: `nes sms gg gb gba a26 md snes pce ps1 n64 pc`. Firmware build steps are in
[esp32/README.md](esp32/README.md); development and debugging tools in
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Repository layout

```
rtl/        Verilog for every system and the board (HDMI, DDR3, ESP32 link, menu)
esp32/      ESP32 firmware: menu, game loading, controllers
sim/        testbenches
tools/      build scripts, reference models, board tools
boards/     pin and timing constraints
hardware/   case and cable
docs/       guide and design notes
```

## Contributing

Bug reports and pull requests are welcome. If you change a core, run its testbenches in `sim/`
first; most systems also have a reference model in `tools/` to compare against.

## Support the project

SiSTer is free and open source. If you enjoy it, you can support its development on
[Ko-fi](https://ko-fi.com/vygandasvalantiejus): it pays for boards, test hardware and time for new systems.

<a href="https://ko-fi.com/vygandasvalantiejus"><img src="https://ko-fi.com/img/githubbutton_sm.svg" alt="Support on Ko-fi"></a>

## License

GPL-3.0, see [LICENSE](LICENSE). Some components come from other projects and keep their own
compatible licences; see [docs/THIRD_PARTY.md](docs/THIRD_PARTY.md). The DOS PC is built on
ao486 by Aleksander Osman and 486Tang by nand2mario.

No games or BIOS files are included. Use your own.
