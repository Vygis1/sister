# The ESP32 front door

What this is: the thing a person connects a phone to in order to change which
console the board is, and which cartridge is in it. It is a control plane and
nothing else -- see `docs/ARCHITECTURE.md` for why the picture does not come
down this path.

## What it needs

- The board on the desk is an **ESP32-S3** (dual core, 240 MHz, 8 MB PSRAM,
  Wi-Fi and BLE 5) on a CH343 USB-serial bridge. The sketch names FSPI and HSPI,
  which is what the S3 calls its two usable SPI buses -- a classic ESP32 has
  VSPI and HSPI instead and will not compile unchanged.
- A microSD card on the second bus, for the core and cartridge library.
- Six wires to the FPGA. Four are SPI; the other two are what make it safe.

## Wiring

    ESP32-S3        FPGA            header U2
    --------        ----            ---------
    GPIO12    ->    esp_sclk        pin 7   (ball D26)
    GPIO11    ->    esp_mosi        pin 8   (ball E26)
    GPIO13    <-    esp_miso        pin 9   (ball D25)
    GPIO10    ->    esp_cs_n        pin 10  (ball E25)
    3V3       <-    3V3             pin 3   (or power the ESP32 over USB)
    GND       <-    GND             pin 61

    GPIO14    ->    PROGRAM_B       optional: forces the shell back
    GPIO21    <-    DONE            optional: says configuration finished

**Do not take power from U2 pins 63 or 64.** Those are VIN -- whatever is
feeding the board -- and they will destroy a 3.3 V module. Pins 1-6 are the
3.3 V rail; pin 3 is confirmed.

Both ends are 3.3 V, so no level shifting. The S3 routes peripherals through a
GPIO matrix, so these pin numbers are a choice: they avoid the strapping pins
(0, 3, 45, 46) and the ones wired to the on-board flash and PSRAM (26-32), which
on an 8 MB-PSRAM part are genuinely not available.

The four SPI wires are all that is needed to talk. The other two are worth
adding once it works: PROGRAM_B is the way back from a core that hangs, and
without it the recovery is reaching for the power lead.

## Wiring the SD card

A **second, separate** SPI bus. It has to be separate: the card is a slow device
that holds chip select for a whole block transfer, and sharing a bus with the
FPGA would mean the board could not be spoken to mid-install -- which is exactly
when progress needs reporting.

    SD module       ESP32-S3
    ---------       --------
    SCK       <-    GPIO5
    MISO      ->    GPIO6
    MOSI      <-    GPIO4
    CS        <-    GPIO7
    VCC       <-    see below -- this is the part that kills modules
    GND       <-    GND

These four are a choice, not a constraint (the S3 has a GPIO matrix), but they
are a considered one: clear of the strapping pins (0, 3, 45, 46), clear of the
flash and PSRAM pins, and clear of the four already going to the FPGA.

### Which voltage the module wants

Micro SD cards are 3.3 V parts. What varies is the BOARD around them, and giving
one the wrong rail either does nothing or destroys the card:

- **Two chips on it** -- a three-pin regulator (usually AMS1117) and an eight-pin
  buffer (usually 74LVC125) -- is a **5 V** module, the common blue "Catalex"
  kind. Feed it **5 V**. Feeding it 3.3 V does not damage it but will not work:
  the regulator needs about a volt of headroom, so the card gets roughly 2.2 V
  and either fails to mount or corrupts on write, intermittently, which is the
  worst way for it to fail.
- **No chips** -- just the socket, a few resistors and a capacitor -- is a bare
  **3.3 V** module. Feed it **3V3** and never 5 V.

If the ESP32-S3 is on USB, its 5V pin has 5 V on it for the first kind.

### If it does not mount

`SD.begin` failing prints `no SD card` at boot. In order of likelihood: the card
is not FAT32 (exFAT is not supported -- reformat as FAT32), VCC is on the wrong
rail for the module type above, MISO and MOSI are swapped (the labels are from
the module's point of view and some boards label them DO/DI instead), or the
card is seated badly. Cards above 32 GB are usually exFAT from the factory and
have to be reformatted.

PROGRAM_B is the one that matters when something has gone wrong: a core that
hangs, a bad flash write, a bitstream for the wrong part. Pulling it low and
releasing it restarts configuration from address 0, which is the shell. Without
that wire the recovery is reaching for the power lead.

## The menu on the TV (menu.h)

The console images carry `esp_bus.v` (this chip drives the register bus over its four
wires, as the PC does over Ethernet) and `osd.v` (40 x 30 text over the HDMI picture).
At power-up the ESP32 boots whatever core the flash slot holds and shows the menu:
the consoles first, then the chosen one's games. Picking a game for another console
goes back to the shell (which shows the install's progress on the TV), installs that
core from `/cores` (a sector at a time, read back and rewritten if wrong), boots it and
loads the game.

    START + SELECT, or a Bluetooth pad's PS / Home    the menu (the NES and Master System pause)
    UP / DOWN, LEFT / RIGHT                          move, a page at a time
    A                                                open a console / load the game
    B                                                back

## The card

    /cores/nes.bin  sms.bin  md.bin  n64.bin  ps1.bin
    /roms/nes/*.nes            /roms/sms/*.sms        /roms/md/*.md *.gen
    /roms/n64/*.z64 *.n64 *.v64                       /discs/*.bin (PlayStation, raw 2352-byte sectors)
    /roms/SCPH*.BIN (or /bios)  the PlayStation BIOS
    /saves/card1.mcr            the PlayStation's memory card (made, formatted, when missing)
    /saves/n64/*.eep            N64 EEPROM saves
    /saves/snes/*.srm           SNES save RAM
    /saves/gb/*.sav             Game Boy battery RAM (+ the MBC3 clock: BGB / VBA-M's 48-byte trailer)
    /saves/gba/*.sav            GBA saves (SRAM 32 kB, flash 64 / 128 kB, EEPROM 512 B / 8 kB)

A game left loose in `/roms` is moved into its console's folder, by its extension, the
first time the card is read.

## The LilyGO T8 (classic ESP32): Bluetooth pads

The S3 has no Bluetooth Classic, which PS4/PS5 pads need. The same sketch builds for a
classic ESP32-WROVER board (the LilyGO T8) on the esp32-bluepad32 platform and then takes
PS4, PS5, Xbox and Switch pads (`pads.h`): each machine gets its own button layout, the
N64 its stick. Pair a PlayStation pad by holding SHARE and PS until the light flashes.

    ./tools/arduino/arduino-cli.exe compile --fqbn "esp32-bluepad32:esp32:esp32:PSRAM=enabled,PartitionScheme=huge_app" esp32/console

    T8          FPGA                header U2
    GPIO18  ->  esp_sclk            pin 7
    GPIO23  ->  esp_mosi            pin 8
    GPIO19  <-  esp_miso            pin 9
    GPIO5   ->  esp_cs_n            pin 10
    GPIO32  ->  PROGRAM_B           (the SW1 wire)
    GND     --  GND                 pin 61
    microSD: the T8's own slot (GPIO 27/12/14/33)

Bluepad32 is Apache-2.0 but runs on BTstack, which is free for non-commercial use only.
The replacement is ESP-IDF's own stack, Bluedroid (Apache-2.0): the same sketch built on the
stock `esp32:esp32` 3.3.11 platform uses it (`pads_bluedroid.h`). It works on the board with a
DualShock 4 and is still opt-in; see [docs/BLUETOOTH.md](../docs/BLUETOOTH.md).

    ./tools/arduino/arduino-cli.exe compile --fqbn "esp32:esp32:esp32:PSRAM=enabled,PartitionScheme=huge_app" --build-path build/fw-t8d-bluedroid esp32/console

A core is a **`.bin`, not a `.bit`**. They are not interchangeable and the
difference is not cosmetic: a `.bit` carries a header -- design name, part,
build date -- in front of the bitstream, and the FPGA's configuration engine
reads that header as bitstream and refuses the lot. `tools/core.sh` writes both
and only the `.bin` is the thing to copy.

The firmware finds cores by listing `/cores` and taking every `.bin`, so adding
a machine is copying a file. There is no index file: an earlier draft of this
document described a `/cores/index.json` mapping ROM extensions to cores, and
nothing ever read it. When there is a reason to map extensions to cores, it goes
here and this paragraph goes away.

## What it does at power-up

1. Mounts the card and scans `/cores` and `/roms` for the menu.
2. Asks the FPGA what it is, with PING. The answer says whether the shell or a
   console core is loaded, and which; a shell gets the slot's core started.
3. Takes Bluetooth pads and draws the menu on the TV. There is no Wi-Fi and no web
   page any more (removed 2026-10-12): on this chip Wi-Fi shared the one radio and the
   internal RAM with Bluetooth, and pads lost and delayed buttons while it was up.
   Cores and games go onto the card in a PC.

Picking a console the board is not currently running means: install the core
into a free slot if it is not already in one, then boot that slot. Picking a
cartridge means streaming it into the running core. The first can take a couple
of seconds; the second is fast.

## Status

Working on hardware, end to end, with no PC in the data path:

    card                 SDXC 238 GB, FAT32, mounted, /cores/nes.bin listed
    install from card    30 sectors erased, 7465 pages written, CRC verified
    boot the core        the NES runs; the PC sees $46504741 "FPGA" over Ethernet
    back to the shell    PROGRAM_B pulled low; the PC sees $5348454C "SHEL"

### The gap worth knowing about

**Only `shell_top.v` instantiates `esp_link`.** A console core does not, so the
moment a core boots, the ESP goes deaf: `alive` reads false and the only control
left is PROGRAM_B. That is enough to be *safe* -- the board can always be
recovered -- but it is not enough for the ESP to be the control plane, because
"which cartridge is in the machine" is a question you ask a RUNNING console.

Giving the console core an `esp_link` is what closes it, and it is the next
piece of work. Until then, a running core is reachable over Ethernet only.

### The card must be FAT32

exFAT is not supported: the SD library here is built without it, and a 256 GB
card is exFAT from the factory. The card size is not the problem and a smaller
card is not the fix -- Windows 11 (build 26100 and later) formats FAT32 far past
the old 32 GB limit, and `sdprobe.cpp` will tell you exactly which of the two
you are looking at rather than making you guess.

### Talking to it over USB

Typed into the serial port at 115200 (what the PC's tools use through tools/pad.py):

    state              what the board is, and what is on the card
    cores              the core library on the card
    install <name>     write a core from the card into the flash slot
    boot / shell       start the installed core / go back to the shell
