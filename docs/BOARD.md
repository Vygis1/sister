# The board: QMTECH XC7A100T

Board facts, constraints and the Vivado flow for the QMTECH Artix-7 core board,
taken from the vendor schematic and checked on the board.

| | |
|---|---|
| Board | QMTECH Artix-7 XC7A100T core board (PCB shared with the 200T) |
| Part | **xc7a100tfgg676-1** — slowest speed grade |
| Fabric | 63,400 LUT · 126,800 FF · 135 × BRAM36 · 240 DSP48 |
| Clock | 50 MHz onboard oscillator, ball **U22** |
| LEDs | **T23**, **R23** |
| I/O | 108 pins on headers U2/U4 — see [`boards/qmtech_a100t/HEADERS.md`](../boards/qmtech_a100t/HEADERS.md) |
| Also on board | 256 MB DDR3, QSPI config flash, 2 push-buttons |
| Toolchain | Vivado 2026.1 — no licence needed for this part |

## Layout

    boards/qmtech_a100t/
      qmtech_a100t.xdc      base constraints: clock, LEDs, config settings
      shell_top.xdc         the menu image (the shell): ESP32 link, flash, HDMI
      ddr3.xdc              the DDR3 pins (tools/migpins.py makes the MIG's pin file from it)
      HEADERS.md            full U2/U4 pin -> ball map, JTAG J1 pinout, wiring warnings
      reference-ps2net.xdc  ps2net's pinout, kept as a worked example of using the headers
    rtl/blink.v             bring-up blinky
    tools/vivado.sh         wrapper: check / build / prog / flash / gui
    tools/check.tcl         is the install usable for this part?
    tools/build.tcl         non-project RTL -> bitstream
    tools/program.tcl       JTAG load, or burn to QSPI
    prebuilt/smoke-a100t.bit  known-good blinky bitstream

## Use

Run these from **Git Bash**, not msys2's `sh` — msys2's `sh` cannot launch
`vivado.bat` and returns success having run nothing.

    ./tools/vivado.sh check                      # toolchain sanity, ~1 min
    ./tools/vivado.sh build                      # rtl/ + base xdc -> build/blink/blink.bit
    ./tools/vivado.sh prog build/blink/blink.bit # load over JTAG (volatile)

A different design:

    ./tools/vivado.sh build -top mydesign -xdc boards/qmtech_a100t/mydesign.xdc

Persist it to the config flash so the board boots standalone:

    ./tools/vivado.sh flash build/blink/blink.bit -mem <cfgmem-part>

This replaces the shell at address 0. Write `cores/shell.bit` back afterwards, or the
console's menu will not start.

The flash part on this board is a Micron **N25Q064A** at U3 (marking `25Q064A` /
`13E40`; the chip's own JEDEC ID reads `20 BA 17`). So, for the menu image:

    ./tools/vivado.sh flash cores/shell.bit -mem n25q64-3.3v-spi-x1_x2_x4

Note the `-spi-x1_x2_x4` suffix. The `n25q64-3.3v-qspi-*` parts also exist and
look like the obvious choice, but they are UltraScale only and Vivado rejects
them for artix7 with a message that reads like the part name is wrong.

## Bring-up

Power and JTAG only: load `prebuilt/smoke-a100t.bit`, or build `blink`. Both LEDs
blinking at visibly different rates means the board, the 3.3 V rail, the
oscillator, JTAG, the Vivado install and the constraint flow all work.

## Programmer

The J1 header is 6 pins: **3V3, TCK, TDO, TDI, TMS, GND** — full table and the
caveat about pins 1/6 in `HEADERS.md`. **VREF (pin 1) is not optional**: without
it a level-shifting cable drives nothing and reports no error that points at the
cause.

Vivado's hardware manager only sees cables it has drivers for — Xilinx Platform
Cable and Digilent. A bare FT2232H breakout will not show up; use
[openFPGALoader](https://github.com/trabucayre/openFPGALoader) for those:

    openFPGALoader -c ft2232 build/blink/blink.bit

## 6502

`rtl/cpu6502.v` is a cycle-accurate NMOS 6502, the CPU of the NES and (with RDY)
the Atari 2600. It passes Klaus Dormann's functional test in full:

    ./tools/sim.sh tb_cpu6502     # ~4 minutes, 96M cycles, 30.6M instructions

Cycle accuracy is the point, not instruction accuracy: NES games time raster
effects by counting CPU cycles, so every bus cycle a real 6502 performs is
performed here, dummy reads included. The NMOS quirks are deliberate — the
`JMP ($xxFF)` page-wrap bug, zero-page index wrapping, B existing only in the
pushed status byte, and decimal ADC/SBC with NMOS flag behaviour.

It also matches **nestest.nes against its published reference log, all 8991
instructions**, official and undocumented opcodes alike:

    ./tools/sim.sh tb_nestest     # then compare build/sim/nestest_out.txt

That is a stronger test than Klaus in one respect: it runs the real NES memory
map, with RAM mirrored four times across $0000-$1FFF and a 16 KB PRG ROM
appearing at both $8000 and $C000. Mirrors are exactly where an address decode
goes wrong.

Three things the two tests check that are easy to get wrong:

- **The NES has no decimal mode.** The 2A03 keeps the D flag but ADC and SBC are
  always binary. `DECIMAL` defaults to 0 for that; Klaus's test instantiates the
  core with `DECIMAL=1` because it exercises real-6502 decimal arithmetic.
- **76 undocumented opcodes** are implemented (LAX, SAX, SLO, RLA, SRE, RRA,
  DCP, ISC and the NOP variants that still perform their read). Real games use
  them, and nestest diverges at exactly the instruction where they begin.
- **RRA is ROR then ADC, and the ADC must see the carry the ROR just made.**
  Reading the flag register gives the value from before the shift, because the
  non-blocking assignment has not landed yet.

Two things to know about Klaus's test:

- **Success is `0x3469`, not the highest self-jump in the image.** Klaus ends
  with `lda #$f0 / sta test_case / jmp *`. The higher trap at `0x382F` belongs
  to the interrupt test, which needs host support the functional test does not
  use. `tb_cpu6502` also checks `test_case == 0xF0` so the pass does not rest on
  a magic address alone.
- **`$0200` is the test-case counter**, not an I/O trigger. Every stage reads
  it, checks it, and stores the next number, which is why a failure address
  tells you which test you were in.
