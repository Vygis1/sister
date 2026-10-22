# Building and using the console

This is the stand-alone console: a TV over HDMI, a menu on the screen, games and
cores on an SD card, PlayStation 4 / 5 (or Xbox, Switch) pads over Bluetooth. No PC
is needed once it is set up.

It plays **NES, Master System, Game Gear, Game Boy, Game Boy Color and Game Boy Advance, Atari 2600, Mega Drive, Super NES, PC Engine, Nintendo 64, PlayStation and DOS PC games**, one at a
time: each console is its own FPGA image, and the board becomes whichever one you
pick from the menu.

- [What you need](#what-you-need)
- [Putting it together](#putting-it-together)
- [The first programming](#the-first-programming)
- [The SD card](#the-sd-card)
- [Playing](#playing)
- [DOS PC games](#dos-pc-games)
- [How well each console runs](#how-well-each-console-runs)
- [When something goes wrong](#when-something-goes-wrong)
- [Legal](#legal)

---

## What you need

| Part | Notes |
|---|---|
| **QMTECH Artix-7 XC7A100T core board** (DDR3, 8 MB SPI flash) | The console. [BOARD.md](BOARD.md) has its facts. |
| **HDMI breakout**: a bare HDMI socket on a 2 x 10 2.54 mm header | Plugs straight onto header U4, pins 7-26. |
| **LilyGO T8** (ESP32-WROVER, microSD slot) | The menu, the SD card, Bluetooth pads. It has to be a *classic* ESP32: the S3, C3 and C6 have no Bluetooth Classic, which PlayStation and Switch pads need. |
| **microSD card**, FAT32 | Cores, games, saves. Cards above 32 GB come exFAT: reformat them as FAT32. |
| **JTAG cable** (Xilinx, Digilent, or an FT2232H with openFPGALoader) | Only for the first programming of the shell. |
| Six short wires (eight for faster loading) | ESP32 to header U2. Keep them short (a few cm): the link runs at up to 10 MHz. |

## Putting it together

**HDMI.** The breakout goes on header U4 pins 7-26, turned so the socket faces
away from the board: HDMI pin *k* lands on U4 pin 27-*k*.

    HDMI 1  D2+   U4 26      HDMI 3  D2-   U4 24
    HDMI 4  D1+   U4 23      HDMI 6  D1-   U4 21
    HDMI 7  D0+   U4 20      HDMI 9  D0-   U4 18
    HDMI 10 CLK+  U4 17      HDMI 12 CLK-  U4 15

The remaining HDMI pins (shields, DDC, hot-plug) are held low by the FPGA, CEC is left
floating (it is the TV's bus), and the +5V pin is held at 3.3 V. The TMDS wires are
plain 3.3 V outputs at the weakest drive strength the chip has: a TV terminates each one
with 50 ohms to 3.3 V, and a stronger driver swings the line several times further than
the HDMI standard allows. One TV took that, a 4K Philips did not ("no signal"). It is
still not a standard TMDS signal; a TV that refuses it wants a powered HDMI splitter in
between, or the socket rewired to true differential pin pairs (see
[HEADERS.md](../boards/qmtech_a100t/HEADERS.md)).

**The ESP32 (LilyGO T8).**

    T8          FPGA                     header U2
    GPIO18  ->  SPI clock                pin 7
    GPIO23  ->  SPI data in              pin 8
    GPIO19  <-  SPI data out             pin 9
    GPIO5   ->  SPI select               pin 10
    GND     --  ground                   pin 61
    GPIO32  ->  PROGRAM_B                the non-ground side of SW1, the board's program button
    GPIO22  ->  quad data 2              pin 12   (optional: loads go about four times faster)
    GPIO21  ->  quad data 3              pin 11   (optional, with GPIO22)

PROGRAM_B is how the ESP32 restarts the FPGA into the shell; it is soldered to the
board's own program button, which is not on any header. Power the ESP32 from its
USB socket. **Never take power from U2 pins 63 / 64**: those are the board's raw
input voltage and will destroy a 3.3 V part.

The firmware also has pin definitions for an ESP32-S3, without Bluetooth Classic or quad
writes; see [esp32/README.md](../esp32/README.md).

## The first programming

The FPGA's flash holds **the shell** at address 0 -- it is what the board starts
into, and what installs the consoles from the SD card. It is written once, over JTAG:

    ./tools/vivado.sh flash cores/shell.bit -mem n25q64-3.3v-spi-x1_x2_x4
    # or, with openFPGALoader:
    openFPGALoader -c <your cable> --fpga-part xc7a100tfgg676 --write-flash cores/shell.bin

`tools/vivado.sh flash` erases only the sectors the shell covers. If the consoles in
the flash are lost some other way, nothing is harmed: a console that does not start is
installed again from the card.

The ESP32's firmware, from a release package (`tools/release.sh` writes one to
`dist/`):

    # LilyGO T8 (Bluetooth pads):
    esptool.py --chip esp32 write_flash 0x0 esp32/console-t8.bin

or build it yourself with the Arduino CLI; the commands are in
[esp32/README.md](../esp32/README.md).

## The SD card

    /cores/nes.bin  sms.bin  gg.bin  gb.bin  gba.bin  a26.bin  md.bin  snes.bin  pce.bin  n64.bin  ps1.bin  pc.bin     the consoles
    /roms/nes/      *.nes
    /roms/sms/      *.sms
    /roms/gg/       *.gg
    /roms/gb/       *.gb *.gbc        (a Color game runs as one: the cartridge's header says)
    /roms/a26/      *.a26 *.bin      (a bank scheme in the name wins: "Game (F8SC).a26")
    /roms/pce/      *.pce            (a 512-byte copier header is skipped)
    /roms/gba/      *.gba            (up to 16 MB; /bios/gba_bios.bin is optional)
    /roms/md/       *.md *.gen
    /roms/snes/     *.sfc *.smc
    /roms/n64/      *.z64 *.n64 *.v64
    /roms/pc/       DOS games: Game.img (its hard disk), Game.cfg, Game.pad, and Game.cue / .bin (its CD) -- see below
    /pc/            the PC's BIOS: boot0.rom (Bochs BIOS) and boot1.rom (VGA BIOS), from 486Tang's tools/
    /discs/         PlayStation discs: a .bin of raw 2352-byte sectors, or a .cue with .bin tracks (also /roms/ps1/)
    /bios/          the PlayStation BIOS (SCPH1001.BIN or another 512 kB SCPH*.BIN)
    /saves/         written by the console: card1.mcr (PlayStation), n64/*.eep, snes/*.srm, gb/*.sav, gba/*.sav
    /menu/          optional: the menu's console logos and button icons (tools/menu/mklogos.py)

Games dropped loose into `/roms` are sorted into their console's folder the first
time the card is read. A PlayStation `.cue` must name `.bin` tracks: audio tracks as MP3 or
WAV files are not read. You supply the games and the BIOS: none come with this.

The card can also be written without taking it out: with the board on USB and
`tools/pad.py` running, `python tools/sdput.py FILE /roms/gg/Game.gg` copies a file
onto it through the ESP32 (fine for cartridges, cores and DOS games; a 700 MB
PlayStation disc is quicker with the card in a reader). Do not update the ESP32's
firmware while a PlayStation disc is being read: the card can be left unreadable until
the board is switched off and on.

## Playing

Turn it on: the board starts the shell and the menu comes up on the TV. (Settings,
System, *At power-up* can start the last game instead.)

| | |
|---|---|
| **Up / Down** | move (Left / Right or L1 / R1: a page at a time) |
| **A** (Cross) or **Start** | open a console's games / play the game / change a setting |
| **B** (Circle) | back |
| **Triangle** | the settings |
| **PS / Home**, or **Start + Select** | the menu, from any game: back to the game, reset, settings, home |

Picking a game for another console switches the board. The flash holds two consoles
besides the menu, and a console already there starts in a few seconds. Otherwise a
progress bar shows while that console is written into the flash (up to about a
minute), then the game starts. Picking another game for the same console takes a few
seconds.

**Pairing a pad:** PS4 / PS5 -- hold SHARE (CREATE) and the PS button until the light
flashes quickly; the ESP32 remembers it after that. Xbox: the pairing button on top.
Switch Pro: the sync button. Two pads can be connected.

On the Super NES the buttons go by position: cross is B, circle A, square Y, triangle X,
L1 / R1 the shoulders.

Saves are written to `/saves` within seconds of the game saving: the PlayStation's
memory card, N64 EEPROM, SNES save RAM, Game Boy battery RAM (with the MBC3 clock) and
Game Boy Advance saves.

**Settings** (the last entry under the consoles):

- **Picture**: the options below. They take effect at once, in the game behind the menu.
- **Controllers**: the connected pads, pairing a new one, a button test, each console's
  button mapping, swapping players 1 and 2, forgetting paired pads.
- **System**: *At power-up* (this menu, or straight into the last game), the start-up
  logo, restarting the console.

| Picture | |
|---|---|
| **Scaling** (N64, PlayStation) | *as the console* (the N64 smooths across the line, as its video chip does), *sharp* (each pixel doubled), *smooth* (blended both ways), *edge-directed* (diagonal edges rounded off) |
| **Scanlines** | off, light, heavy -- dark lines between the picture's, as a CRT showed them |
| **N64 VI filters** | *as the game* asks the N64's video chip: edge anti-aliasing, dither removal, the divot filter; or *off* (the raw picture), or *all on* |
| **N64 dedither** | *as the game*, or *always*: takes the checkerboard dither out of 16-bit colour |
| **N64 gamma** | *as the game*, or *off* |
| **N64 dither** | *as the game*, or *off*: the N64 draws with no dither at all (smooth colour, a little banding) |

## DOS PC games

The PC is one more console in the menu. Each game is a hard-disk image with DOS and the game
already on it, so a game starts like any cartridge: pick it, and the PC boots straight into it.

**Adding a game** (on the PC, with WSL for the disk tools):

    python tools/pc/addgame.py "Some Game.zip"          # a DOS game folder or zip
    python tools/pc/addgame.py "Some Game" --out build/pc --run "CD GAME|GAME.EXE"

`addgame.py` makes `Some Game.img`: a bootable hard disk with FreeDOS, the game, a Sound Blaster
16 set up (220h, IRQ 7, DMA 1, as DOSBox has it), the mouse driver, an 8 MB disk cache (LBACACHE:
the disk is on the SD card, at the other end of the ESP32), and the CD-ROM driver when the
game has a CD. It also makes `Some Game.cfg`, and `Some Game.cue` / `.bin` from a CD image in the
game's folder. They go to `/roms/pc/` on the SD card when the card is in the PC, or to `--out`
(default `build/pc/games`); copy them over with `tools/sdput.py` while the card is in the console.
The game starts with its own start `.BAT`, else with the `.EXE` named like its folder; `--run`
gives the commands instead, separated by `|`. `addgame.py --dos` makes "FreeDOS", a plain DOS
prompt.

**The pad on a PC game.** By default the pad plays Doom (arrows, fire, use, run, strafe). A file
beside the game, `Some Game.pad`, maps it for anything else, one button a line:

    a = enter               # cross on a PlayStation pad
    b = esc                 # circle
    x = mouse_left          # square
    y = mouse_right         # triangle
    up = arrowup
    l1 = ctrl, alt          # up to three keys pressed together
    lstick = mouse          # the left stick moves the mouse
    mouse_speed = 4         # how fast (counts every 10 ms at full tilt)

Buttons: `up down left right a b x y l1 r1 l2 r2 start select` (a / b / x / y by position: cross,
circle, square, triangle). Keys are PC key names: `a`-`z`, `0`-`9`, `f1`-`f12`, `enter`, `esc`,
`space`, `tab`, `backspace`, `shift`, `ctrl`, `alt`, `arrowup` / `arrowdown` / `arrowleft` /
`arrowright`, `home`, `end`, `pageup`, `pagedown`, `insert`, `delete`, the keypad's `kp0`-`kp9`,
`kpplus`, `kpminus`, `kpstar`, `kpenter`, punctuation (`comma`, `period`, `minus`, `equals`,
`slash`, `semicolon`, `quote`, `lbracket`, `rbracket`, `backslash`, `backquote`), and
`mouse_left`, `mouse_right`, `mouse_middle`. A button the file leaves out does nothing. A keyboard on the
PC running `tools/pad.py` also types into the game.

## How well each console runs

| Console | State |
|---|---|
| NES | Full speed. Mappers 0, 1, 2 and 4 (NROM, MMC1, UxROM, MMC3). |
| Master System | Full speed. |
| Game Gear | The Master System core with the Gear's palette and START. |
| Game Boy | Game Boy and Game Boy Color: passes the standard CPU and picture tests (dmg-acid2, cgb-acid2). MBC1, MBC3 and MBC5; battery saves and the MBC3 clock on the SD card. |
| Game Boy Advance | The processor passes the ARM7TDMI single-step suite; Pokémon Emerald plays, with its clock. The open BIOS is built in; a real one at /bios/gba_bios.bin is used instead when present. |
| PC Engine | HuCards; the processor passes the 65C02 single-step suite. No CD-ROM. |
| Atari 2600 | Bank switching 2K-32K. Select / Reset are on the pad's Select / Start. |
| Mega Drive | Stereo. Cartridges up to 4 MB. |
| Super NES | Plays Super Mario World; save RAM kept on the SD card. LoROM and HiROM cartridges up to 6 MB; no add-on chips (Super FX, SA-1, DSP-1...). Hi-res screens are shown 256 wide. |
| PlayStation | Boots the real BIOS and plays commercial games (Crash Bandicoot, Syphon Filter, Tekken 2, MediEvil): memory card, CD audio and XA from the disc image, FMVs. Details in [PLAYSTATION.md](PLAYSTATION.md). |
| Nintendo 64 | Plays Super Mario 64, Mario Kart 64 and Super Smash Bros., close to the console's speed; other games are untested. EEPROM saves. Details in [N64.md](N64.md). |
| DOS PC | A 486 at 71.4 MHz (ao486), 32 MB, VGA and VESA SVGA, Sound Blaster 16 + OPL3, CD-ROM with CD audio. Doom, Rayman, Transport Tycoon Deluxe, Fallout. No FPU. |

## When something goes wrong

- **No picture at all:** check the HDMI breakout is the right way round (the socket
  faces outward).
- **The menu does not appear:** the ESP32 cannot reach the FPGA. Check the four SPI
  wires and the ground; short wires.
- **A switch ends on the shell's screen:** the core on the card is missing or did
  not write right; the menu tries each sector three times. Re-copy the core file.
- **"no SD card":** FAT32 only.
- **Stuck:** press the board's program button (SW1). It restarts into the shell and
  the menu comes back.

## Legal

The consoles are written from public documentation and checked against public test
programs. The DOS PC is the exception: it is built from open-source projects (ao486, 486Tang,
the OPL3, MiSTer's cache and IDE code), each under its own licence -- see
[THIRD_PARTY.md](THIRD_PARTY.md). Games, the PlayStation BIOS and DOS games are copyrighted:
use your own. Bluepad32 (the Bluetooth pads) is
Apache-2.0 but runs on BTstack, which is free for non-commercial use only.
