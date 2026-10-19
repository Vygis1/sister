# Development

How the cores are built, simulated and debugged on the board. Using the console is covered in
[GUIDE.md](GUIDE.md).

## The setup

```
  PC ──USB serial (2 Mbaud)── ESP32 (LilyGO T8) ──SPI, 4-bit writes── FPGA ──HDMI── TV
  │                            │ SD card: cores, games, saves           │ DDR3: RAM, VRAM,
  │                            │ Bluetooth controllers                  │ cartridges
  └── JTAG cable (optional) ───────────────────────────────────────────┘
```

Everything the PC does to the board goes through the ESP32's USB serial port. `pc/pad.py` holds
that port and opens a local tool port, **127.0.0.1:5557**, that every board tool talks to:

| Line | Does |
|---|---|
| `R <addr>` | read a 32-bit register on the FPGA's bus |
| `W <addr> <value>` | write one |
| `S <command>` | a command for the ESP32's serial console (see below) |

The ESP32's output is logged to `build/pad.log`. Logging is off after every ESP32 reset;
`pad.py` turns it on when it connects.

```sh
python pc/pad.py                       # keep running in its own window
python tools/bcmd.py "state"           # the ESP32's state: reset reason, clock, card, FPGA
python tools/bcmd.py -r 80010 80014    # console registers: frame counter, CPU position
```

## Common tasks

| Task | Command |
|---|---|
| Build a core | `./tools/core.sh <system>` → `cores/<system>.bin` (only if timing passes) |
| Put a file on the SD card | `python tools/sdput.py cores/nes.bin /cores/nes.bin` (~165 kB/s, read back and checked) |
| Start a game | `python tools/bcmd.py "play /roms/snes/Game.sfc"` (installs the core if needed) |
| List a folder on the card | `python tools/bcmd.py "ls /roms/pc"` |
| See the picture | `python tools/vgrab.py out.png` (most systems) · `tools/pc/pcgrab.py` · `tools/n64/fbgrab.py` · `tools/ps1/espshot.py` |
| Check every system | `python tools/coreshots.py nes sms gg md snes pce gb gba a26` (installs, plays, grabs) |
| Back to the menu image | `python tools/bcmd.py -w 14 B0070000` |
| Flash the ESP32 | stop `pad.py`, then `python -m esptool --chip esp32 --port COM9 --baud 921600 write-flash 0x10000 build/fw-t8d/console.ino.bin` |

ESP32 serial commands worth knowing (`S` lines, or `bcmd.py "<command>"`): `state`, `log on`,
`cores`, `ls <dir>`, `play <path>`, `vgrab [step]`, `quadtest`, `ds` (the clock chip),
`pcstat`, `pctime`, `pcboot <image>`, `pcread <image> <sector>`, `pclink`, `kb <scancodes>`,
`bulk <hz>`, `quad off|on`. They are all in `esp32/console/console.ino` (`serialCommand`).

## Building

| | |
|---|---|
| FPGA | Vivado 2026.1. `tools/core.sh` wraps `tools/build.tcl`; `EFFORT=1`, `AREA=1`, `RETIME=1`, `PLACE_DIR=<directive>` tune a run, `RELEASE=1` leaves out debug hardware. Reports land in `build/core_<name>/`. |
| ESP32 | `tools/arduino/arduino-cli.exe compile --config-file tools/arduino/arduino-cli.yaml --fqbn "esp32-bluepad32:esp32:esp32:PSRAM=enabled,PartitionScheme=huge_app" --build-path build/fw-t8d esp32/console` |
| DOS disk images | `python tools/pc/addgame.py <game folder or zip>` (WSL: `mtools`, `nasm`, `sfdisk`) |

Vivado uses about 1.5 cores a run: independent builds go faster in parallel than one after another.

## Simulation

```sh
./tools/sim.sh tb_line_grab            # one testbench (Vivado's xsim); fails on any "FAIL" line
./tools/simall.sh                      # the regression
```

- Benches are in `sim/`. Large systems have their own runners: `tools/simps1.sh`, the N64 model
  in `tools/n64/`, and the DOS PC under Verilator in `sim/pc/` (`make`, or `make Z486=1`).
- Reference models (Python) sit beside each system's tools: the PlayStation's SPU
  (`tools/ps1/spu_ref.py`), the N64 (`tools/n64/n64model.py`), the GBA's picture unit
  (`tools/gba/ppuref.py`), the menu (`tools/menu/ui_model.cpp`).
- `tools/vfuncscan.py` finds Verilog function patterns that xsim simulates wrongly.

## Debugging on the board

- **Is it running?** `tools/coretest.py` reads each core's frame counter and CPU position.
- **What does it show?** The picture grabbers above read the actual HDMI output or framebuffer.
- **Why did the ESP32 restart?** `state` prints the last reset's cause (crash, watchdog, brown-out)
  and what the PC's disk task was doing.
- **Deeper:** debug images (`JTAG=1 ./tools/core.sh <system>`) carry a JTAG-to-AXI bridge, read
  with `tools/jtag.py`. Per-system debug registers are described in the system docs.

## Conventions

- A bug found on the board gets a testbench that shows it, wherever one can.
- A core lands in `cores/` only if it meets timing; `cores/<name>.src` records the sources it was
  built from.
- Third-party code keeps its licence headers; changes to it are noted in the file and listed in
  [THIRD_PARTY.md](THIRD_PARTY.md).
