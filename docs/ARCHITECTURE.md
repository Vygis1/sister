# How the console works

The console is two boards. The FPGA board runs one game system at a time and sends its
picture and sound to HDMI. The ESP32 (a LilyGO T8) runs everything around it: the menu, the
SD card, installing systems, loading games, serving discs and hard disks, saving games and
reading Bluetooth controllers. There is no network of any kind.

```
  Bluetooth pads ))) ESP32 (LilyGO T8) ==== SPI link, 4-bit writes ==== FPGA board ── HDMI ── TV
                     │ microSD card                                     │ configuration flash
                     │ USB serial (optional PC)                         │ 256 MB DDR3
                     └── PROGRAM_B wire ────────────────────────────────┘
```

Video and audio never cross the link. The FPGA makes them and drives the HDMI socket itself.

## Where things are stored

| Store | Size | Holds |
|---|---|---|
| FPGA configuration flash (N25Q064) | 8 MB | the menu image and two installed systems |
| microSD card on the ESP32 | any, FAT32 | every system image, every game, BIOS files, saves, menu art |
| DDR3 on the FPGA board | 256 MB | large memories of the running system: cartridges, RAM, VRAM |
| FPGA block RAM | 135 × 36 kb | what must answer in one clock: video memory, line buffers, caches |

### The flash

The FPGA can only configure itself from this flash, so a system has to be in it to run.

| Address | Size | Contents |
|---|---|---|
| `0x000000` | 2 MB | the menu image, called the *shell*. Loaded at every power-up. |
| `0x200000` | 3 MB | slot 0: an installed system |
| `0x500000` | 3 MB | slot 1: another installed system |

The shell itself only knows one rule: an erase or a write is an offset below 6 MB, added to
`0x200000` (`rtl/shell_flash.v`). The split into two 3 MB slots is the firmware's
(`SLOT1_OFF`, `SLOT_HALF` in `esp32/console/menu.h`). A system image larger than 3 MB goes in
slot 0 and uses the space of both. The ESP32 records which image is in which slot in its own
non-volatile storage (name and size).

Images are compressed bitstreams (`BITSTREAM.GENERAL.COMPRESS`). They are raw `.bin` files: a
`.bit` file carries a header that the FPGA's configuration engine rejects.

### The SD card

```
/cores/<system>.bin     the system images: nes sms gg gb gba a26 md snes pce n64 ps1 pc
/roms/<system>/         the games, one folder per system (see GUIDE.md for file types)
/discs/                 PlayStation discs (also accepted in /roms/ps1)
/bios/                  BIOS files: the PlayStation's SCPH*.BIN, optionally gba_bios.bin
/pc/                    the DOS PC's BIOS: boot0.rom and boot1.rom
/saves/                 written by the console: card1.mcr, n64/, snes/, gb/, gba/
/menu/logos/, /menu/icons/   optional menu art (tools/menu/mklogos.py)
```

The menu lists every `.bin` in `/cores` and every system folder in `/roms`. A game left
loose in `/roms` is moved into its system's folder, by its extension, when the card is read.
The card must be FAT32.

## The link

The ESP32 is the SPI master and the FPGA the slave. The same wires reach the shell and every
system image, and each answers the commands it knows.

| ESP32 (T8) | Signal | FPGA header U2 |
|---|---|---|
| GPIO18 | SCLK | pin 7 |
| GPIO23 | MOSI, data 0 | pin 8 |
| GPIO19 | MISO, data 1 | pin 9 |
| GPIO5 | CS | pin 10 |
| GPIO22 | data 2 | pin 12 |
| GPIO21 | data 3 | pin 11 |
| GPIO32 | PROGRAM_B | the non-ground side of SW1 |
| GND | ground | pin 61 |

SPI mode 0, most significant bit first. The FPGA samples the pins in its own clock domain
(`rtl/esp_link.v`), so the SPI clock must stay well below the FPGA's clock: it needs about four
FPGA clocks per SPI period.

- **Short frames** (status, commands, single register reads and writes) run at 5 MHz.
- **Bulk transfers** (game data, disc sectors, flash blocks) run at 10 MHz by default. The
  menu sets this clock from the running image's own clock.
- **Quad writes** send the data four bits per clock, on MOSI, MISO, data 2 and data 3, high
  nibble first. The command and address still go one bit per clock; the FPGA releases MISO
  for the data. A quad write carries about 3.9 MB/s.

### Frames

Chip select low to high is one frame. Byte 0 from the ESP32 is the command; the rest is its
payload. There is no length field. The FPGA's first byte out is always `0xA5`, so one byte
answers "is a configured image listening". Reply bytes come back one byte behind the byte
that asked for them.

Every image answers:

| Command | Payload | Reply |
|---|---|---|
| `01` PING, `02` STATUS | — | `A5`, version, image id, busy |

The image id is `0` for the shell, or the system's letter: `N` NES, `S` Master System,
`G` Game Gear, `B` Game Boy, `V` Game Boy Advance, `A` Atari 2600, `M` Mega Drive,
`F` Super NES, `E` PC Engine, `P` PlayStation, `6` Nintendo 64, `C` DOS PC.

The shell's flash commands (`rtl/shell_top.v`; offsets are 3 bytes, relative to `0x200000`):

| Command | Payload | Does |
|---|---|---|
| `15` UNLOCK | `C0 DE 5A FE` | allows the next erase or write, within 50 ms |
| `10` ERASE | offset | erase one 64 kB sector |
| `11` WRITE | offset, 256 bytes | program one page |
| `19` WRITE, quad | offset, 256 bytes | the same, data four bits per clock |
| `1A` BUFFER, quad | word index, data | fill the shell's 16 kB block buffer |
| `1B` PROGRAM | offset, n | program the buffer's first n pages (1-64) |
| `16` SUM | absolute address | checksum a 64 kB block of the flash |
| `17` SUM READ | 8 bytes | the checksum |
| `12` READ | absolute address | fetch one page into the buffer |
| `13` PAGE | 257 bytes | the fetched page |
| `20` BOOT | `0`, `1` or `2` | restart from `0x000000`, `0x200000` or `0x500000` |

After an erase, write, program, sum or read, the ESP32 polls STATUS until the operation has
started and then until it is no longer busy.

Every system image has a 32-bit register bus behind the link (`rtl/esp_bus.v`). The shell
has one too, for the menu's picture; it accepts writes there and nowhere else.

| Command | Payload | Does |
|---|---|---|
| `40` BUS WRITE | address (4 bytes), then 32-bit words | write words to consecutive addresses |
| `43` BUS WRITE, quad | the same | the same, data four bits per clock |
| `41` BUS READ | address, 4 bytes of wait | one word |
| `42` BUS READ BLOCK | address, 4 bytes of wait | words for as long as CS stays low |

Addresses are big-endian; words are little-endian. The PlayStation image adds its disc
commands (`rtl/cd_feed.v`):

| Command | Payload | Does |
|---|---|---|
| `30` CD STATUS | — | the sector the drive wants next, how many it has room for, disc and motor state |
| `31` CD SECTOR | LBA (3 bytes), 2352 bytes | one raw sector; dropped unless it is the one asked for |
| `32` CD DISC | 1 byte | a disc is in (1) or the tray is empty (0) |

The ESP32's side of all of this is `esp32/console/link.h`.

## Starting a system

When the player picks a game for a system that is not running, the ESP32
(`switchTo` in `esp32/console/menu.h`):

1. Sends the running system back to the shell: it writes `0xB0070000` to bus address
   `0x0014`, and the image restarts the FPGA from address 0 (`rtl/icap_reboot.v`). If the
   shell does not answer within two seconds, the ESP32 pulses PROGRAM_B.
2. If a slot already holds this system's image (same name and size), skips to step 4.
3. Otherwise it writes the image from `/cores` into the slot used less recently. Each 64 kB
   sector is erased; the data goes into the shell's block buffer in 16 kB pieces by quad
   writes, and the shell programs the pages itself. The shell then checksums each 64 kB block
   and the ESP32 compares the sum with its own. A block that does not match is erased and
   written again, up to three times. The shell's own screen (`rtl/shell_screen.v`) or the
   graphical menu shows the progress.
4. Sends BOOT with the slot. The shell writes the slot's address to the FPGA's WBSTAR register
   and issues IPROG through ICAPE2; the FPGA reconfigures from that address.
5. Waits for STATUS to report the system's id. If it does not, the ESP32 returns to the shell
   and installs the image once more.

Switching to a system that is already in a slot takes a few seconds. While the menu shows a
system that is in neither slot, the ESP32 erases the less recently used slot in the
background, one sector at a time, so a later install has less to do.

## Loading a game

Games go into the running system over the register bus (`load` in `esp32/console/menu.h`):

1. The ESP32 holds the system in reset and selects which machine the image runs, where an
   image has more than one.
2. It reads the file in 16 kB pieces, one piece ahead, on the other CPU core, and sends each
   piece by quad writes into the cartridge window. Large cartridges go through a 256 kB window
   with a bank register, into DDR3.
3. The FPGA folds every word it receives, with its address, into a checksum (bus address
   `0x0018`). The ESP32 computes the same sum and sends a piece again if they differ.
4. It writes the cartridge's settings (mapper, size, save type), then releases reset.

Some systems need more from the card while they run:

- **PlayStation.** The BIOS and the memory card are loaded into DDR3 first. The disc stays on
  the card. The ESP32 reads sectors ahead of the drive into a ring in its PSRAM, on one CPU
  core, and sends each one the drive asks for from the other. It also decodes the disc's XA audio (`esp32/console/xa.h`) and feeds the
  samples to the drive.
- **DOS PC.** The ESP32 loads the BIOS files and the game's configuration, then serves the hard
  disk image sector by sector as the PC asks (`esp32/console/pc.h`), and the CD-ROM drive from a
  `.cue` / `.bin` image (`esp32/console/cdrom.h`).

## Controllers

The ESP32 reads Bluetooth controllers (`esp32/console/pads.h`), maps their buttons for the
running system, and writes them into the system's pad registers. A pad write goes ahead of
any bulk transfer waiting for the link. A controller on a PC can also be relayed over USB
(`tools/pad.py --relay`).

## Saves

The ESP32 watches the running system's save memory and writes it to `/saves` on the card
shortly after the game changes it: the PlayStation's memory card (`/saves/card1.mcr`), N64
EEPROM, SNES save RAM, Game Boy battery RAM with the MBC3 clock, and GBA SRAM, flash and EEPROM.

## The menu

In the shell, the menu is a picture composed by the FPGA (`rtl/shell_ui.v`). The ESP32 uploads
fonts and images once, then writes a short list of objects for each page: a background,
rounded rectangles, text and images. The FPGA draws each line from the list just before the
TV shows it. `tools/menu/ui_model.cpp` renders the same lists on a PC, and `sim/tb_shell_ui.v`
compares the two pixel for pixel.

Over a running game, the menu is text drawn by the system image (`rtl/osd.v`: 40 × 30 cells of
16 × 16 pixels over the picture). It offers: back to the game, reset, settings, and home.

## Why the board cannot be bricked

- The FPGA always configures from address 0 at power-up, and that is the shell.
- The shell cannot write to its own area: erase and write offsets are checked and added to
  `0x200000` in one place, `rtl/shell_flash.v`. Reads are absolute and cannot damage anything.
- An erase or write is accepted only straight after the five-byte unlock frame. Noise on the
  wires, for example while the ESP32 resets, cannot erase a slot.
- The shell's bitstream enables `CONFIGFALLBACK`: if an image in a slot fails to load, the FPGA
  returns to the shell.
- The ESP32 drives PROGRAM_B (the board's SW1 button) low to force a restart into the shell.
  It only ever pulls it low or leaves it as an input, so the button and the ESP32 cannot fight.
- JTAG works regardless of what is in the flash.

## A PC on the USB port

The ESP32's USB serial port (2 Mbaud) has a text console: board state, the card, installing,
reading and writing registers, copying files onto the card. `tools/pad.py` holds that port and
lets other PC tools use it through 127.0.0.1:5557. See [DEVELOPMENT.md](DEVELOPMENT.md).
