# Changelog

## 0.1.0 — first release

Four consoles on the QMTECH Artix-7 XC7A100T. Each is its own image: the
shell switches between them and brings the board back if a core hangs.

**NES.** A cycle-accurate 6502 (Klaus Dormann's test, and all 8,991 logged
instructions of nestest). The 2C02 PPU, the APU, and mappers 0 and 4.

**Master System.** Z80 (ZEXDOC and ZEXALL), VDP, SN76489, Sega mapper.

**Mega Drive.** 68000 and Z80, VDP with DMA, YM2612, SN76489, with
cartridges in DDR3.

**PlayStation.**
- **Hardware:** R3000A with the GTE, GPU, SPU, CD-ROM, DMA, timers, pad and
  memory card.
- **What runs:** it boots the real BIOS, to its menu or to a game. Crash
  Bandicoot runs at 30 fps in its levels.
- **CPU speed:** the CPU runs on every 50 MHz clock, and the console keeps its
  own 33.8688 MHz for timers, video and sound (ctrl 0xEC bit 12 restores
  console pace).
- **Sound:** the full SPU (24 voices, ADSR, reverb), bit-exact against a model
  built from DuckStation and psx-spx.
- **Disc:** from the PC over Ethernet, or from the ESP32's SD card, which reads
  ahead faster than a real double-speed drive.
- **Memory card:** in slot 1, kept in a `.mcr` file on the PC (the DuckStation
  format); every sector a game saves is copied back within a fraction of a
  second.
- **Not yet:** CD audio (CD-DA, XA), the SPU's capture buffers, a second pad
  and card, and video out of the board itself.

**The page** (`pc/server.py`, `web/`):
- It streams the picture and stereo sound to the browser.
- It takes games and the BIOS by drag and drop, and plays with a keyboard or
  any gamepad, with every button remappable.
- It switches machines and shows the PlayStation's BIOS, disc and memory card.
- Behind the Developer toggle are a logic analyser, a synth, the PHY and a
  register view.

**Known issues**
- **Mega Drive: no sound on the board.**
  - The picture and games run, but the core's audio output holds one level.
  - The FM chip passes its simulation checks and has not yet been heard on
    hardware. The fault is in the sound driver or the FM keying on the board.
- **PlayStation:**
  - While running, about one frame in ten can take 50 ms instead of 33 ms: the
    drawing engine is late on busy scenes.
  - On the title screen, one frame shows a strip of junk in the top rows as the
    sign drops in.
- **Slot panel:** a cartridge loaded by anything other than the page (the API,
  the tools) shows as "nothing loaded".

**The ESP32-S3 front door** (`esp32/console`) is a phone-sized page. It shows
what the board is running and which disc is in the drive, installs cores from
its SD card, and joins Wi-Fi.
