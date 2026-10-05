# Changelog

## 0.2.0 -- the stand-alone console

**HDMI, a menu, no PC.** The board drives a TV through an HDMI breakout on header U4,
and an ESP32 with an SD card runs it: a menu over the picture, the games loaded
from the card, the console switched by writing its image into the flash.

- **HDMI** (`rtl/hdmi_tx.v`): 640 x 480, TMDS through ODDR gearboxes as
  pseudo-differential pairs; HDMI audio in data islands -- 48 kHz, or 44.1 kHz for
  the PlayStation and N64 -- checked symbol by symbol (`tools/hdmi_check.py`).
- **Every console on it:** the NES with its palette, the Master System and Mega
  Drive at their own colour depths (`frame_hdmi.v`), the N64 and PlayStation a line
  at a time out of DDR3 (`n64_vid.v`; the PlayStation's frame double-buffered),
  each doubled and centred. Stereo for the Mega Drive, PlayStation and N64.
- **The menu** (`esp32/console/menu.h`, `rtl/osd.v`): the consoles, then the games
  from `/roms/<console>` and `/discs`; the pad, a Bluetooth pad's PS / Home button
  or Start + Select opens it and pauses the NES and Master System.
- **The ESP32 drives the console** (`rtl/esp_bus.v`, `bus_arb.v`): game loads,
  every chunk checked against a sum the FPGA keeps; PlayStation memory card and
  N64 EEPROM saves on the card.
- **Switching console:** back to the shell (a reboot register, or PROGRAM_B), the
  core written sector by sector and read back, booted; the shell shows the progress
  on the TV.
- **Bluetooth pads** on a classic ESP32 (LilyGO T8) through Bluepad32 (`pads.h`).
- **The NES's sound:** the frame sequencer ran at twice its rate (notes too short),
  a negated sweep muted pulse 1, the noise ran an octave low; the dot clock is
  exactly NTSC now.
- **The NES's picture:** a $2007 read of tile ROM came back from the name table
  about half the time. Super Mario Bros. reads its title screen that way, and drew
  it as garbage that stayed in its status bar through every demo.
- **The Mega Drive's sprites:** a sprite attribute cache and an engine on every
  clock -- sprites late in a long list were not drawn.
- **The Mega Drive's sound:** the Z80 gets the VDP's vertical-blank interrupt (it
  was tied off), and a Z80 stopped by the 68000 in the middle of a read keeps its
  own byte (the RAM had one port, switched to the 68000). Battletoads and other
  games whose sound driver runs on the interrupt were silent.
- **The N64's sound:** the audio interface's clock summed in too few bits and
  wrapped, so it played 24,636 of SM64's 32,006 samples a second; the game's
  buffers piled up and it dropped them, which is what broke the sound up.
- **The N64's speed:** the HDMI picture's reads no longer hold the memory port a
  round trip each, the RSP's DMA writes are queued and pipelined (SM64's microcode
  spent a third of its time waiting on its DMA): 20.6 drawn frames a second to
  24.4 so far, the goal being SM64's 30.
- **The guide:** [docs/GUIDE.md](docs/GUIDE.md).

## 0.1.x -- unreleased changes after 0.1.0

**PlayStation.**
- **CD audio.** The drive has a table of contents and plays audio tracks: Play,
  report mode, auto-pause, GetTN, GetTD, GetlocP, Mute, and the volume matrix.
  An audio CD answers GetID as one, and the BIOS opens its CD player.
- **Audio tracks from MP3.** A `.cue` disc's tracks can be `.bin`, WAV, MP3,
  FLAC or OGG files, decoded once into `build/cdda_cache/`.
- **XA-ADPCM.** The drive applies the game's filter and queues each XA sector.
  The PC decodes and resamples it exactly as DuckStation does
  (`pc/cdaudio.py`), and sends the samples back to the drive.
- **The SPU's capture buffers**, with the IRQ on them, and CD audio in the mix
  and the reverb.
- **A second pad and memory card** (`saves/card2.mcr`). A second gamepad on the
  page is player 2.
- **Fixed:** a data read over audio sectors stalled the drive. It now passes
  over them, as a real drive does, and a read that reaches the end of the disc
  ends with INT4.
- **Fixed:** the table of contents was built as flip-flops (2,800 LUTs), and
  the image stopped routing. It is LUT RAM again.
- **Checked on the board:**
  - `tools/ps1/ps1cdtest.py` plays one XA channel out of eight, then an MP3 track;
  - the BIOS's CD player plays an MP3 track and a WAV track in full;
  - `tools/ps1/ps1slot2test.py` checks the second pad and card.
- **Known:**
  - XA and audio tracks need the disc served by the PC; the ESP32 serves a
    single `.bin`.
  - `tb_ps1_cdbios` and `tb_ps1_cddma` fail, as they did at 0.1.0. They are not
    in the gate.

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
