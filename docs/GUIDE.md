# Building and using the console

This is the stand-alone console: a TV over HDMI, a menu on the screen, games and
cores on an SD card, PlayStation 4 / 5 (or Xbox, Switch) pads over Bluetooth. No PC
is needed once it is set up.

It plays **NES, Master System, Mega Drive, Nintendo 64 and PlayStation**, one at a
time: each console is its own FPGA image, and the board becomes whichever one you
pick from the menu.

- [What you need](#what-you-need)
- [Putting it together](#putting-it-together)
- [The first programming](#the-first-programming)
- [The SD card](#the-sd-card)
- [Playing](#playing)
- [How well each console runs](#how-well-each-console-runs)
- [When something goes wrong](#when-something-goes-wrong)
- [Legal](#legal)

---

## What you need

| Part | Notes |
|---|---|
| **QMTECH Artix-7 XC7A100T core board** (DDR3, 8 MB SPI flash) | The console. [BOARD.md](BOARD.md) has its facts. |
| **LAN8720 Ethernet module** on header U4 | Required for now even without a network: the console images and the shell take their 50 MHz clock from it. |
| **HDMI breakout**: a bare HDMI socket on a 2 x 10 2.54 mm header | Plugs straight onto header U4, pins 7-26. |
| **LilyGO T8** (ESP32-WROVER, microSD slot) | The menu, the SD card, Bluetooth pads. It has to be a *classic* ESP32 -- the S3, C3 and C6 have no Bluetooth Classic, which PlayStation pads need. (An ESP32-S3 also works, without Bluetooth pads.) |
| **microSD card**, FAT32 | Cores, games, saves. Cards above 32 GB come exFAT: reformat them as FAT32. |
| **JTAG cable** (Xilinx, Digilent, or an FT2232H with openFPGALoader) | Only for the first programming of the shell. |
| Six short wires | ESP32 to header U2. Keep them short (a few cm): the link runs at 5 MHz. |

## Putting it together

**HDMI.** The breakout goes on header U4 pins 7-26, turned so the socket faces
away from the board: HDMI pin *k* lands on U4 pin 27-*k*.

    HDMI 1  D2+   U4 26      HDMI 3  D2-   U4 24
    HDMI 4  D1+   U4 23      HDMI 6  D1-   U4 21
    HDMI 7  D0+   U4 20      HDMI 9  D0-   U4 18
    HDMI 10 CLK+  U4 17      HDMI 12 CLK-  U4 15

The remaining HDMI pins (shields, CEC, DDC, hot-plug) are held low by the FPGA and
the +5V pin is held at 3.3 V, which is all a TV needs to see a source.

**The ESP32 (LilyGO T8).**

    T8          FPGA                     header U2
    GPIO18  ->  SPI clock                pin 7
    GPIO23  ->  SPI data in              pin 8
    GPIO19  <-  SPI data out             pin 9
    GPIO5   ->  SPI select               pin 10
    GND     --  ground                   pin 61
    GPIO32  ->  PROGRAM_B                the non-ground side of SW1, the board's program button

PROGRAM_B is how the ESP32 restarts the FPGA into the shell; it is soldered to the
board's own program button, which is not on any header. Power the ESP32 from its
USB socket. **Never take power from U2 pins 63 / 64**: those are the board's raw
input voltage and will destroy a 3.3 V part.

(On an ESP32-S3: GPIO12 / 11 / 13 / 10 for clock / data in / data out / select,
GPIO14 for PROGRAM_B, and an SD module on GPIO5 / 6 / 4 / 7 -- see
[esp32/README.md](../esp32/README.md).)

## The first programming

The FPGA's flash holds **the shell** at address 0 -- it is what the board starts
into, and what installs the consoles from the SD card. It is written once, over JTAG:

    ./tools/vivado.sh flash shell.bit -mem n25q64-3.3v-spi-x1_x2_x4
    # or, with openFPGALoader:
    openFPGALoader -c <your cable> --fpga-part xc7a100tfgg676 --write-flash shell.bin

Writing the shell this way erases the console slot as well; the menu installs a
console again the first time you pick a game.

The ESP32's firmware:

    # LilyGO T8 (Bluetooth pads):
    esptool.py --chip esp32 write_flash 0x0 console-t8.merged.bin
    # ESP32-S3:
    esptool.py --chip esp32s3 write_flash 0x0 console-s3.merged.bin

or build it yourself (Arduino CLI, the esp32-bluepad32 platform for the T8 -- the
commands are in [esp32/README.md](../esp32/README.md)).

## The SD card

    /cores/nes.bin  sms.bin  md.bin  n64.bin  ps1.bin     the consoles
    /roms/nes/      *.nes
    /roms/sms/      *.sms
    /roms/md/       *.md *.gen
    /roms/n64/      *.z64 *.n64 *.v64
    /discs/         PlayStation discs: .bin, raw 2352-byte sectors, one data track
    /bios/          the PlayStation BIOS (SCPH1001.BIN or another 512 kB SCPH*.BIN)
    /saves/         written by the console: card1.mcr (PlayStation), n64/*.eep

Games dropped loose into `/roms` are sorted into their console's folder the first
time the card is read. You supply the games and the BIOS: none come with this.

## Playing

Turn it on: the board starts the shell, the ESP32 starts the console last
installed, and the menu comes up on the TV.

| | |
|---|---|
| **Up / Down** | move (Left / Right: a page at a time) |
| **A** (Cross) | open a console's games / play the game |
| **B** (Circle) | back |
| **PS / Home**, or **Start + Select** | the menu, from any game (the NES and Master System pause under it) |

Picking a game for another console switches the board: the shell shows "SWITCHING
CONSOLE" and a bar while it writes that console into the flash (about a minute),
then the game starts. Picking another game for the same console takes a few seconds.

**Pairing a pad:** PS4 / PS5 -- hold SHARE (CREATE) and the PS button until the light
flashes quickly; the ESP32 remembers it after that. Xbox: the pairing button on top.
Switch Pro: the sync button. Two pads can be connected.

Saves: the PlayStation's memory card and the N64's EEPROM are written to `/saves`
within seconds of the game saving.

## How well each console runs

| Console | State |
|---|---|
| NES | Full speed, sound right. Mappers 0-4 and 7 (NROM, MMC1, UxROM, CNROM, MMC3, AxROM). |
| Master System | Full speed. |
| Mega Drive | Full speed, stereo. Cartridges up to 4 MB. |
| PlayStation | Boots the real BIOS, plays commercial games (Crash Bandicoot at 30 fps), memory card, CD audio from the disc image. |
| Nintendo 64 | Runs Super Mario 64, slower than the real console in busy scenes; the RDP (graphics) is still being completed. |

## When something goes wrong

- **No picture at all:** the LAN8720 module must be plugged in (it is the clock).
  Check the HDMI breakout is the right way round (the socket faces outward).
- **The menu does not appear:** the ESP32 cannot reach the FPGA. Check the four SPI
  wires and the ground; short wires.
- **A switch ends on the shell's screen:** the core on the card is missing or did
  not write right; the menu tries each sector three times. Re-copy the core file.
- **"no SD card":** FAT32 only.
- **Stuck:** press the board's program button (SW1) -- it restarts into the shell,
  and the ESP32 starts the console again.

## Legal

The consoles are written from public documentation and checked against public test
programs; no code from other FPGA console projects is in them. Games and the
PlayStation BIOS are copyrighted: use your own. Bluepad32 (the Bluetooth pads) is
Apache-2.0 but runs on BTstack, which is free for non-commercial use only.
