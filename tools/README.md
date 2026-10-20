# tools

Run everything from the repository root (`./tools/core.sh md`, `python tools/ps1/ps1shot.py`).

## Building, simulating, releasing

| | |
|---|---|
| `core.sh <core>` | an FPGA image: `nes`, `sms`, `gg`, `gb`, `gba`, `a26`, `md`, `snes`, `pce`, `ps1` (`EFFORT=1`), `n64` (`AREA=1`), `pc`, `shell`; published to `cores/` with its source stamp, only when it meets timing |
| `vivado.sh` | Vivado in batch mode: `build`, `prog`, `flash`, `check`, `proj`, `mig`, `gui` (`build.tcl`, `program.tcl`, `check.tcl`, `project.tcl`, `mig.tcl`, `ooc.tcl`) |
| `sim.sh <tb>` | one testbench from `sim/` in xsim; `simall.sh` runs the regression, `simps1.sh` the PlayStation's |
| `release.sh` | the package in `dist/`: images, ESP32 firmware, source, checksums |
| `srcstamp.py` | what an image was built from, so `release.sh` can tell a stale one |
| `board.sh` | build and program the development image in one step |
| `migpins.py` | the DDR3 controller's pin file, from `boards/qmtech_a100t/ddr3.xdc` |
| `gen_osd_font.py` | `rtl/osd_font.v`, the menu's font |
| `vfuncscan.py` | finds Verilog function patterns xsim simulates wrongly |
| `longpaths.tcl`, `longpaths.py` | a routed design's failing paths, grouped by module |
| `vidref.py` | the reference for the N64 video filters, and the gate for `tb_n64_vid` |
| `menu_art.py`, `menu/` | the menu's tiles, font and logos (`esp32/console/art.h`, `gfx_font.h`) |
| `hdmi_check.py` | checks the HDMI data islands a bench recorded |
| `mipsasm.py` | a MIPS assembler, for the PlayStation's and the N64's test programs |
| `menu_preview/` | renders the ESP32 menu to a PNG on the PC |

## The board, from the PC

| | |
|---|---|
| `serve.sh` | starts `pc/server.py` (the development setup, [docs/DEVELOPMENT.md](../docs/DEVELOPMENT.md)) |
| `esp.py` | the ESP32's serial console |
| `bcmd.py` | one ESP32 console command, or console register reads/writes, through `pc/pad.py` (`bcmd.py "ls /roms/nes"`, `bcmd.py -r 80010`) |
| `coretest.py` | starts a game on every console in turn and checks that each one runs (frame counter, CPU position) |
| `vgrab.py` | the picture a core sends to the TV, as a PNG (`rtl/line_grab.v`; not in the PS1 / N64 images) |
| `sdput.py` | a file onto the SD card through the ESP32, checked by reading it back (~165 kB/s) |
| `menunav.py`, `toolpad.py` | drive the on-screen menu / press pad buttons from the PC |
| `jtag.py` | the console's registers over the JTAG cable (debug images) |
| `padpress.py` | presses buttons on pad 1 |
| `playtest.py` | loads a cartridge and reads frames back |
| `fb2png.py`, `frame2png.py` | framebuffers and bench frame dumps to PNG |
| `shellscope.py` | records the shell's pins |
| `console.py`, `win.sh` | run a command in a window of its own |
| `uicheck.js` | loads the web page's scripts as a browser would |

## Per console

Reference models, test-program generators, test runners and board debugging scripts.

| | |
|---|---|
| `nes/` | `nes2hex.py` (cartridge to bench hex), `uxtest.py` |
| `sms/` | the Z80 test harnesses (`z80hw.py`, `z80rom.py`, `z80shim.py`), Master System loading and screenshots |
| `md/` | the 68000 assembler and tests, the YM2612's tables, `mdtest.py` |
| `ps1/` | the GTE model and its hardware vectors, the SPU reference (`spu_ref.py`), the R3000 test program, CD and XA tools, and the board debugging scripts (`ps1shot.py`, `ps1status.py`, `ps1flash.py`, ...) |
| `n64/` | the N64 model (`n64model.py`: CPU, FPU, RSP, RDP), the krom test runners, the table generators, and the board debugger `n64dbg.py` |
| `snes/` | Python models of the 65816, SPC700, DSP and PPU; the SingleStepTests and krom runners |
| `gb/` | the SM83 single-step runner, blargg runner, cgb-acid2 check, frame tools |
| `gba/` | the ARM7TDMI single-step converter, the BIOS converter, the reference renderer `ppuref.py` |
| `pce/` | the 65C02 single-step runner, frame tools, the Mednafen comparison |
| `a26/` | a 6502 assembler and disassembler, bank-switching gate, the NTSC palette |
| `pc/` | `addgame.py` (a DOS game onto the card), `mkdisk.sh`, `pccfg.py`, `pcgrab.py` (the PC's screen), `pctype.py` |
