# ESP32 firmware

`esp32/console` is the firmware for the ESP32 next to the FPGA. It runs the menu, reads the SD
card, installs systems into the FPGA's flash, loads games, serves PlayStation discs and the DOS
PC's hard disk and CD-ROM, reads Bluetooth controllers and saves games to the card. It carries
no video or audio: the FPGA drives HDMI itself. How the two boards work together is in
[docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md).

## The board

The console uses a **LilyGO T8 V1.7.1** (ESP32-WROVER: a classic ESP32 with 4 MB flash and
PSRAM, and a microSD slot). It has to be a classic ESP32: PlayStation and Switch pads use
Bluetooth Classic, which the ESP32-S3, C3 and C6 do not have.

The sketch also has pin definitions for an ESP32-S3 (FPGA link on GPIO 12/11/13/10, PROGRAM_B on
GPIO14, an SD module on GPIO 5/6/4/7). That build has no Bluetooth Classic and no quad writes.

## Wiring (T8)

    T8          FPGA                 header U2
    GPIO18  ->  SPI clock            pin 7
    GPIO23  ->  SPI data in          pin 8
    GPIO19  <-  SPI data out         pin 9
    GPIO5   ->  SPI select           pin 10
    GPIO22  ->  quad data 2          pin 12
    GPIO21  ->  quad data 3          pin 11
    GPIO32  ->  PROGRAM_B            the non-ground side of SW1, the board's program button
    GND     --  ground               pin 61

Power the T8 from its own USB socket. **Never take power from U2 pins 63 or 64**: they carry
whatever feeds the board and will destroy a 3.3 V part. Both boards are 3.3 V, so no level
shifting is needed.

The quad wires (GPIO 21 and 22) are optional; without them every transfer is one bit per clock
and loading is slower. PROGRAM_B is how the ESP32 restarts the FPGA into the shell when a system
hangs. The firmware only ever pulls it low or leaves it as an input, so it cannot fight the
button.

The microSD card is the T8's own slot: GPIO 14 (clock), 15 (command / MOSI), 2 (data 0 / MISO),
13 (CS), read over SPI at 20 MHz. GPIO12 is the module's flash-voltage strap and is not used.

## The card

FAT32 only. Cards larger than 32 GB usually come formatted exFAT and have to be reformatted.

    /cores/      nes.bin sms.bin gg.bin gb.bin gba.bin a26.bin md.bin snes.bin pce.bin n64.bin ps1.bin pc.bin
    /roms/nes/   *.nes             /roms/snes/  *.sfc *.smc        /roms/gba/  *.gba
    /roms/sms/   *.sms             /roms/n64/   *.z64 *.n64 *.v64  /roms/a26/  *.a26 (and *.bin)
    /roms/gg/    *.gg              /roms/gb/    *.gb *.gbc         /roms/pce/  *.pce
    /roms/md/    *.md *.gen *.smd  /roms/pc/    DOS games: <name>.img, .cfg, .pad, .cue / .bin
    /discs/      PlayStation discs: .bin (raw 2352-byte sectors) or .cue with .bin tracks
    /bios/       the PlayStation BIOS (SCPH*.BIN, 512 kB); optionally gba_bios.bin
    /pc/         boot0.rom and boot1.rom, the DOS PC's BIOS and VGA BIOS
    /saves/      written by the console: card1.mcr, n64/*.eep, snes/*.srm, gb/*.sav, gba/*.sav
    /menu/       optional menu art: logos/ and icons/ (tools/menu/mklogos.py)

A system's folder can also have its long name (for example `/roms/genesis`, `/roms/gameboy`,
`/roms/ps1` for discs). A game left loose in `/roms` is moved into its system's folder by its
extension when the card is read. Only `.a26` marks an Atari game; an Atari `.bin` has to be put
in `/roms/a26` by hand.

A system image is a **`.bin`**, not a `.bit`. A `.bit` file starts with a header (design name,
part, date) that the FPGA's configuration engine rejects. `tools/core.sh` writes both; copy the
`.bin`.

## Building

With the Arduino CLI in `tools/arduino/`. There are two variants; they differ only in the
Bluetooth stack (see [docs/BLUETOOTH.md](../docs/BLUETOOTH.md)).

    # Bluepad32 (the default; on the esp32-bluepad32 platform)
    ./tools/arduino/arduino-cli.exe compile --fqbn "esp32-bluepad32:esp32:esp32:PSRAM=enabled,PartitionScheme=huge_app" --build-path build/fw-t8d esp32/console

    # Bluedroid (opt-in; on the stock esp32:esp32 3.3.11 platform)
    ./tools/arduino/arduino-cli.exe compile --fqbn "esp32:esp32:esp32:PSRAM=enabled,PartitionScheme=huge_app" --build-path build/fw-t8d-bluedroid esp32/console

Bluepad32 is Apache-2.0 but runs on BTstack, which is free for non-commercial use only. The
Bluedroid build uses ESP-IDF's own stack (Apache-2.0) and works on the board with a DualShock 4.

Flashing, with `tools/pad.py` stopped so the serial port is free:

    python -m esptool --chip esp32 --port COM9 --baud 921600 write-flash 0x10000 build/fw-t8d/console.ino.bin

Do not flash while a PlayStation disc is being read: the SD card can be left unreadable until
the board is switched off and on.

## Files

| File | What |
|---|---|
| `console.ino` | setup, the PlayStation disc and XA tasks, the serial console, installing from the card |
| `link.h` | the FPGA link: frames, quad writes, flash commands, the register bus, PROGRAM_B |
| `menu.h` | the menu's pages, loading games, the two flash slots, switching systems, saves |
| `gfx.h`, `gfxmenu.h`, `gfx_font.h`, `ui_list.h` | the graphical menu, as an object list for `rtl/shell_ui.v` |
| `ui.h`, `screens.h`, `art.h` | the text menu over a running game (`rtl/osd.v`) |
| `pads.h` | controllers: Bluetooth or the PC's relay, each system's button mapping |
| `pads_bluedroid.h` | the Bluedroid Bluetooth backend |
| `pc.h`, `cdrom.h` | the DOS PC: starting it, its hard disk, its ATAPI CD-ROM, its keyboard |
| `xa.h` | the PlayStation's XA-ADPCM audio decoder (checked by `tools/ps1/xatest.py`) |
| `card.h`, `sdprobe.cpp`, `sdprobe.h` | the SD card, and a diagnosis when it does not mount |
| `log.h` | the log, off until `log on` |

`esp32/linktest`, `esp32/usbpad` and `esp32/usbprobe` are small standalone sketches for testing
the FPGA link and USB pads.

## At power-up

1. The FPGA loads the shell; the ESP32 mounts the card and lists `/cores` and the game folders.
2. It asks the FPGA what it is (STATUS). In the shell, the menu comes up on the TV.
3. With *At power-up: the last game* set in the menu's System page, it starts the last game.

## The serial console

On the USB serial port at 2 Mbaud. `tools/pad.py` holds the port and passes other tools'
commands through; see [docs/DEVELOPMENT.md](../docs/DEVELOPMENT.md).

| Command | Does |
|---|---|
| `state` | what the board is, the card, the last reset's cause |
| `cores` | the system images on the card |
| `install <name>` | write `/cores/<name>.bin` into slot 0 |
| `boot`, `shell` | start slot 0 / pull PROGRAM_B, back to the shell |
| `play <path>` | start a game, switching system if needed |
| `ls <dir>`, `rm <path>`, `mv <a> <b>` | the card |
| `disc <path>`, `eject`, `disc` | the PlayStation's disc |
| `pads`, `btactive on\|off` | Bluetooth state |
| `log on`, `log off` | the log |
| `vgrab` | a row of the HDMI picture, for `tools/vgrab.py` |
| `pcstat`, `pctime`, `pcboot <image>`, `pcread <image> <sector>`, `pclink`, `kb <codes>` | the DOS PC |
| `quadtest`, `linkbench`, `bulk <hz>`, `quad off\|on` | the link |

The full list is `serviceSerial` in `console.ino`.
