# tools

Run everything from the repository root (`./tools/core.sh md`, `python tools/ps1/ps1shot.py`).

## Building, simulating, releasing

| | |
|---|---|
| `core.sh <core>` | an FPGA image: `nes`, `sms`, `md`, `ps1` (`EFFORT=1`), `n64` (`AREA=1`), `shell`; published to `cores/` with its source stamp |
| `vivado.sh` | Vivado in batch mode: `build`, `prog`, `flash`, `check`, `proj`, `mig`, `gui` (`build.tcl`, `program.tcl`, `check.tcl`, `project.tcl`, `mig.tcl`, `ooc.tcl`) |
| `sim.sh <tb>` | one testbench from `sim/` in xsim; `simall.sh` runs the regression, `simps1.sh` the PlayStation's |
| `release.sh` | the package in `dist/`: images, ESP32 firmware, source, checksums |
| `srcstamp.py` | what an image was built from, so `release.sh` can tell a stale one |
| `board.sh` | build and program the development image in one step |
| `migpins.py` | the DDR3 controller's pin file, from `boards/qmtech_a100t/ddr3.xdc` |
| `gen_osd_font.py` | `rtl/osd_font.v`, the menu's font |
| `vfuncscan.py` | finds Verilog function patterns xsim simulates wrongly |
| `hdmi_check.py` | checks the HDMI data islands a bench recorded |
| `mipsasm.py` | a MIPS assembler, for the PlayStation's and the N64's test programs |
| `menu_preview/` | renders the ESP32 menu to a PNG on the PC |

## The board, from the PC

| | |
|---|---|
| `serve.sh` | starts `pc/server.py` (the development setup, [docs/DEVELOPMENT.md](../docs/DEVELOPMENT.md)) |
| `esp.py` | the ESP32's serial console |
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
