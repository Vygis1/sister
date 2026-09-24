# Where everything lives

Three questions, and they have different answers because they have different
constraints:

- **Cores** — 1.9 MB bitstreams. Only one place on earth can load them, and it
  is not negotiable: the board's configuration flash.
- **Cartridges** — 32 kB to 4 MB ROMs. Need to be in front of the CPU core at
  full speed, and need to be picked from a library of hundreds.
- **The front door** — what a person touches to change either of those.

## The four stores

    ESP32 microSD        the library      every core, every cartridge
    board SPI flash      the boot medium  shell + 3 resident cores, 8 MB
    board DDR3           the cartridge    256 MB, volatile
    board block RAM      the machine      video, work RAM, line buffers

Each one is there because of a hard property the others do not have.

**The SPI flash is the only thing the FPGA can boot from.** That is the whole
reason it is special. It is 8 MB, which is four bitstreams, which is why it
cannot be the library:

    0x000000   shell        golden image, loads on power-up, never rewritten
    0x200000   core slot 1  2 MB
    0x400000   core slot 2  2 MB
    0x600000   core slot 3  2 MB

**The SD card is the only thing that is big and removable.** A 32 GB card holds
every Master System and NES cartridge ever pressed several times over, and the
user can fill it on a PC without any of this software being involved. Layout:

    /cores/nes.bit            /roms/nes/*.nes
    /cores/sms.bit            /roms/sms/*.sms
    /cores/megadrive.bit      /roms/megadrive/*.md
    /cores/index.json         which core a file extension wants

**The DDR3 is the only thing both big and fast.** A 4 MB Mega Drive cartridge
does not fit in block RAM under any arrangement and does not need to: it is a
ROM being read a byte at a time, which is what DDR3 with a small cache is good
at. It is volatile, so it is a copy, never the original.

**Block RAM is the only thing with single-cycle latency**, so it keeps what the
renderer touches every pixel and nothing else. That is the whole reason to move
the cartridge out: the design is at 98% of 135 tiles today, and 96 of those are
cartridge.

## How a thing gets from the card to the screen

Changing the core:

    phone -> ESP32 -> shell -> SPI flash -> ICAPE2 -> the core is now a NES

    1. The ESP32 reads /cores/nes.bit off the card.
    2. It streams it to the shell, which erases 32 sectors and programs
       8192 pages into a slot.
    3. It tells the shell to boot that slot. The shell writes the address into
       WBSTAR and issues IPROG. The chip reconfigures.

    Only step 2 is slow, and only the first time: a core already in a slot is
    booted in step 3 alone, which is milliseconds.

Changing the cartridge:

    phone -> ESP32 -> core -> DDR3 -> the game is running

    No reconfiguration, no flash write. Seconds.

## What each part is for

**The ESP32 is a control plane, not a data plane.** It picks cores and
cartridges, serves the page that picks them, and nothing else. It does not
carry video: 256x240 at 60 Hz is 22 MB/s and an ESP32's Wi-Fi is not close.
Video and audio stay on the Ethernet link today and move to HDMI when the
connector exists.

Saying this plainly now avoids the obvious trap — building a beautiful ESP32
web UI and then discovering the picture cannot come down it.

**The shell is deliberately tiny.** Flash writer, the ESP32 link, ICAPE2, and
a status word. Nothing that could fail to fit, nothing that changes when a core
changes. It is the golden image and its job is to always work.

**Power-up always loads address 0**, so a broken core cannot brick the board:
pull the power and the shell comes back. If even that fails, the ESP32 holds
PROGRAM_B and can force it.

## The link between the ESP32 and the FPGA

SPI, ESP32 as master, four wires plus two.

    ESP32           FPGA header      why
    -----           -----------      ---
    SCLK    ->      esp_sclk         up to 40 MHz
    MOSI    ->      esp_mosi
    MISO    <-      esp_miso
    CS      ->      esp_cs_n
    IO      ->      PROGRAM_B        force the shell back, the last resort
    IO      <-      DONE             did configuration finish

UART was the alternative and is not good enough: 2 MB at 3 Mbaud is seven
seconds of staring at a progress bar, per core install. SPI at 20 MHz is under
a second, and the pins are there.

The protocol is one byte of command, then a payload:

    0x01  PING                        -> 0xA5, version, what core is running
    0x02  STATUS                      -> flash busy, slot contents, core id
    0x10  FLASH_ERASE   slot          erase one 2 MB slot: 32 sectors
    0x11  FLASH_WRITE   slot, off,    one 256-byte page
                        256 bytes
    0x12  FLASH_VERIFY  slot          -> CRC32 of the slot
    0x20  BOOT          slot          WBSTAR + IPROG, no reply, the chip is gone
    0x30  CART_LOAD     off, len,     stream a ROM into cartridge memory
                        data
    0x31  CART_INFO     mapper, size  what the core should believe about it
    0x40  RESET         run           hold or release the console core
    0x41  INPUT         pad1, pad2    a control pad over Wi-Fi, if wanted

A flash write is one page and not one kilobyte because the board has one page
buffer and no way to say "wait" in the middle of a frame. Programming a page
takes about twice as long as clocking one in, so anything larger would overrun.
The master sends a page, then polls STATUS until the board stops being busy.

That sets the honest cost of installing a core, and it is worth writing down
rather than discovering: 32 sector erases at most of a second each is about
twenty seconds, and 8192 page programs at half a millisecond is four more. The
SPI link is not the slow part and making it faster would not help. Booting a
core already in a slot is a single command and a reconfiguration -- under a
second, which is the number that actually matters, because that is the one a
person does repeatedly.

Commands 0x01-0x02 and 0x40-0x41 exist in every image. 0x10-0x20 are the
shell's. 0x30-0x31 are a console core's. So the same four wires and the same
framing serve both, and the ESP32 does not need to know which image is loaded
before it can ask.

## Order of work

1. `esp_link.v` — the SPI slave and command decode. Testable on its own, and
   needed by both the shell and the cores.
2. `shell_top.v` — that plus `spi_flash.v` plus ICAPE2. The golden image.
3. ESP32 firmware — Wi-Fi AP, web page, SD card, the client side of the above.
4. `CART_LOAD` in the console cores, so a ROM can arrive without a PC.
5. DDR3, so the cartridge stops eating block RAM and Mega Drive becomes
   possible.
