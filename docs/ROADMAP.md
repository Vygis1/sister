# Roadmap

What works, what doesn't yet, and what comes next, system by system. The history of how it got
here is in [CHANGELOG.md](../CHANGELOG.md).

Legend: ✅ done · 🔧 in progress · ⬜ planned

## Systems

### Nintendo 64
- ✅ Super Mario 64 and Mario Kart 64 play; SM64 at 27-30 of its 30 frames a second
- ✅ Saves (EEPROM) on the SD card; the VI's filters selectable in the menu
- ⬜ Full speed in every scene (the RSP and RDP's throughput)
- ⬜ YUV textures and the remaining RDP modes
- ⬜ Super Smash Bros. boots

### PlayStation
- ✅ Real BIOS, disc images, memory cards, CD audio, XA streaming, MDEC movies
- ✅ Commercial games at their own frame rates (Crash Bandicoot, Syphon Filter, Tekken 2, ...)
- ⬜ High-resolution (480i) menus, such as Gran Turismo 2's
- ⬜ The remaining ps1-tests that DuckStation passes

### DOS PC
- ✅ ao486 at 62.5 MHz: Doom, Rayman (CD), Transport Tycoon Deluxe, Fallout
- ✅ SVGA, Sound Blaster 16 + OPL3, ATAPI CD-ROM with CD audio, mouse from the controller
- ✅ A game is one command away: `tools/pc/addgame.py`
- ⬜ A faster CPU path to memory (Doom's demo3 runs at 15.6 fps today)

### Super Nintendo
- ✅ LoROM and HiROM up to 6 MB, save RAM on the SD card
- ⬜ Enhancement chips: DSP-1, Super FX, SA-1
- ⬜ Hi-res modes at their full 512 pixels

### Game Boy / Game Boy Color
- ✅ Both models, MBC1/3/5; cgb-acid2 pixel-exact on the board
- ⬜ Battery saves on the SD card

### Game Boy Advance
- ✅ Pokémon Emerald with its clock; the open BIOS built in
- 🔧 Saves on the SD card (written; to be confirmed on the board)
- ⬜ OBJ mosaic, prefetch accuracy

### PC Engine
- ✅ HuCards, multitap
- ⬜ CD-ROM²

### NES · Master System · Game Gear · Mega Drive · Atari 2600
- ✅ Playable; see [CONSOLES.md](CONSOLES.md) for mapper and cartridge coverage
- ⬜ NES: more mappers (VRC, MMC5)

## The console

- ✅ Graphical menu composed by the FPGA, Bluetooth controllers, settings, saves on the card
- ✅ Every system checked by picture on the board (`tools/coreshots.py`)
- ⬜ Faster core switching (two flash slots)
- ⬜ HDMI with true differential pairs (some TVs reject the current pseudo-differential signal)

## The project

- ⬜ A licence (see [PUBLISHING_RISKS.md](PUBLISHING_RISKS.md))
- ⬜ Release packages: FPGA images and ESP32 firmware, with notices for third-party parts
