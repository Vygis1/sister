# The shell

The shell is the FPGA image at address 0 of the configuration flash. The board loads it at
every power-up. It holds the menu's picture and the engine that writes system images into the
flash and starts them. Each system (NES, PlayStation and so on) is a separate image with the
whole chip to itself; the shell is how the board changes from one to another.

How the shell fits into the console, the flash layout and the link protocol are in
[ARCHITECTURE.md](ARCHITECTURE.md). This page covers the shell image itself.

## What is in it

`rtl/shell_top.v`, built with `./tools/core.sh shell` into `cores/shell.bin` and
`cores/shell.bit`.

| Part | Module | Does |
|---|---|---|
| The flash door | `esp_link.v` + the command decode in `shell_top.v` | the ESP32's flash commands: unlock, erase, write, buffer, program, sum, read, boot |
| The flash engine | `shell_flash.v`, `spi_flash.v` | erase, program and read the N25Q064; the address rule |
| The register bus | `esp_bus.v` | the ESP32's writes to the menu's pages (and nothing else) |
| The menu's picture | `shell_ui.v`, `shell_hl.v` | the graphical menu, composed from an object list; the selection highlight |
| The progress screen | `shell_screen.v`, `osd.v` | "SWITCHING CONSOLE" and a bar while an image is installed, until the ESP32 draws |
| HDMI | `hdmi_tx.v`, `hdmi_clk.v` | 640 × 480 out of the U4 header |
| Reconfiguration | ICAPE2, STARTUPE2 | WBSTAR + IPROG; the flash clock pin |

## Versions

STATUS returns a version byte, and the ESP32 uses only what the shell's version has. The
current shell is version 7.

| Version | Adds |
|---|---|
| 2 | the menu drawn by the shell (text, and the pad register) |
| 3 | a picture under the text |
| 4 | the picture composed from an object list (`shell_ui.v`) |
| 5 | quad writes on the register bus (`43`) |
| 6 | quad page writes (`19`); a 64 kB block checksum (`16`, `17`) |
| 7 | the 16 kB block buffer (`1A`) programmed by the shell (`1B`); two slots, chosen by BOOT's byte |

## Starting an image

The FPGA can reconfigure itself:

1. The shell writes the target address (`0x200000` for slot 0, `0x500000` for slot 1, or 0)
   into the warm-boot start register, WBSTAR, through the ICAPE2 primitive.
2. It issues the IPROG command.
3. The FPGA restarts configuration from that address.

A system image goes back to the shell the same way, with WBSTAR = 0 (`rtl/icap_reboot.v`).

## The flash pins

After configuration the flash's pins are ordinary I/O, except its clock, which can only be
driven through STARTUPE2.

| Ball | Flash pin | Use |
|---|---|---|
| R14 | D00 / MOSI | data out |
| R15 | D01 / DIN | data in |
| P14 | D02 / W# | held high |
| N14 | D03 / HOLD# | held high |
| P18 | FCS_B | chip select |
| H13 | CCLK | through STARTUPE2's `USRCCLKO` |

The flash is used one bit wide. The board pulls the unused pins low, and in single-bit mode D02
and D03 are write protect and hold: left low, they would block every write. The shell drives
them high.

## Details the flash engine depends on

- **Erase is one 64 kB sector per command.** The ESP32 erases the sectors it is about to write
  and no others.
- **Busy means "anything outstanding".** It includes the clock in which a command has been
  accepted but the flash chip has not yet raised its own busy flag. Otherwise a status poll in
  that gap reads "finished" for an operation that has not started. The ESP32 also waits to see
  busy before it waits for idle (`waitDone` in `esp32/console/link.h`).
- **Reply counters do not wrap inside a frame.** A page read is 258 bytes.
- **Erase and write need the unlock frame** (`15 C0 DE 5A FE`) just before them, so noise on
  the wires while the ESP32 resets cannot look like an erase.

## Tests

| Bench | Checks |
|---|---|
| `sim/tb_spi_flash.v` | the flash controller against `sim/spiflash_model.v`, a Micron N25Q model |
| `sim/tb_shell.v` | the whole shell, driven over the SPI wires; offsets far outside the slot area must leave everything below `0x200000` untouched |
| `sim/tb_shell_stock.v` | the shell's built-in picture before the ESP32 draws (a frame to `build/shell_stock.ppm`) |
| `sim/tb_shell_ui.v` | the menu picture, pixel for pixel against `tools/menu/ui_model.cpp` |
| `sim/tb_shell_screen.v` | the progress screen |
| `sim/tb_esp_link.v`, `sim/tb_esp_bus.v` | the link and the register bus |

## Writing the shell

The shell is written once, over JTAG, as described in [GUIDE.md](GUIDE.md#the-first-programming).
After that the ESP32 only writes the slot area, which the shell cannot let it leave.
