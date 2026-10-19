# Third-party components

An inventory of everything in this tree, or fetched by its tools, that was not written for this
project. It covers who wrote each piece, its licence, where that licence is stated, and what the
licence requires of us.

Audit date: 2026-10-18, on branch `ps1-area-and-stream`. Method: `git ls-files`,
`git status --porcelain --untracked-files=all`, the file headers, and a byte-for-byte comparison
against the upstream clones in `build/dl/` (which is ignored and not part of the repo).
Where no licence could be found, this file says **unknown** rather than guessing.

**State** column:
- **tracked**: the file is in git now.
- **untracked**: the file is not committed yet, and `git add -A` would add it.
- **fetched**: the file is downloaded at build time and never committed.

---

## 1. Summary: what the licences force

| Licence found | Where | Consequence |
|---|---|---|
| **GPL-3.0** | `rtl/pc/soc/sound/opl3/afifo.v` (used by the OPL3), `esp32/console/cdrom.h` | Any **PC-core bitstream** is a combined work under GPL-3, and so is the **ESP32 console firmware**. `console.ino` includes `pc.h`, and `pc.h` includes `cdrom.h` unconditionally. Distributing either binary obliges you to offer the complete corresponding source under GPL-3. That includes our own files compiled into it (`console_top.v`, `shell_*`, `mem_arb.v`, the other cores' sources in the same build, and all of `esp32/console/`). So our own code must carry a GPL-3-compatible licence. |
| **GPL-3 vs BTstack** | ESP32 firmware built for the LilyGO T8 (`esp32-bluepad32` platform) | BTstack (under Bluepad32) is "free for non-commercial use only". That is an additional restriction, which GPL-3 section 7/10 forbids. A T8 firmware binary containing both `cdrom.h` and BTstack **cannot be distributed** under consistent terms. Building it for yourself is fine. |
| **LGPL-3.0-or-later** | OPL3 (`rtl/pc/soc/sound/opl3/*.sv`) | The OPL3 files stay LGPL. Keep their headers, ship their source with any binary, and mark our change to `opl3_pkg.sv`. GPL-3 can absorb it. |
| **GPL-2.0-or-later** | `rtl/pc/soc/sound/saa1099.sv` | It is not used (its instance is commented out in `sound.v`, and it is not in `files.f`). Dropping the file removes the question. |
| **Apache-2.0** (partial scope) | `rtl/pc/z486/` | Keep `LICENSE-z486`. Apache 4(b) requires a prominent "changed" notice in each file we modified. **The microcode and PLA ROM files are outside the grant** (see 2.3). Apache-2.0 is compatible with GPL-3. |
| **BSD-2/BSD-3, MIT, ISC-style** | ao486, 486Tang, Cult-of-GBA BIOS, parallel-RDP table, QRCode | Keep the copyright notices with the source, and reproduce them in the documentation of any binary distribution (bitstreams, firmware, release zips). |
| **OFL-1.1** | Nunito font (`tools/menu/fonts/`, rendered into `esp32/console/gfx_font.h`) | Keep `OFL.txt` next to the font. The font may not be sold on its own. The FSF calls OFL GPL-incompatible for software. A rendered bitmap embedded as data in a GPL firmware is generally treated as aggregation, but note it. |
| **Public domain** | font8x8 (`rtl/osd_font.v`, `rtl/osd_glyphs.v`) | None. Credit is courteous. |
| **No grant / unknown** | z486 microcode + PLA ROMs, `iobus_adapter.sv`, `pic_inta_bridge.sv`, `uart_fixed.v` | See `docs/PUBLISHING_RISKS.md`. |

---

## 2. Vendored source in the tree

### 2.1 The PC core: ao486 by way of 486Tang (`rtl/pc/`, untracked)

Upstream: nand2mario's **486Tang**, https://github.com/nand2mario/486tang (clone at `b3de0a8`, 2026-05-03).
486Tang is itself a port of **ao486_MiSTer**, https://github.com/MiSTer-devel/ao486_MiSTer, and
that is Aleksander Osman's **ao486** with changes by Alexey Melnikov (Sorgelig) and others.
`rtl/pc/README.md` records this. The files were compared with `build/dl/pc/486tang/src/`. Everything
is byte-identical (ignoring CR/LF) **except** the files marked *modified* below.

| Path | Author(s) | Licence (where stated) | Modified? | Used in build? |
|---|---|---|---|---|
| `rtl/pc/LICENSE-486tang` | nand2mario | **BSD-3-Clause**, "Copyright (c) 2025, nand2mario" (the file itself, identical to 486tang/LICENSE) | -- | -- |
| `rtl/pc/LICENSE-ao486_MiSTer` | Aleksander Osman | **BSD-2-Clause** text (two conditions, no endorsement clause): "All files in the following directories: rtl, ao486_tool, sim are licensed under the BSD license", "Copyright (c) 2014, Aleksander Osman". Identical to ao486_MiSTer/LICENSE. It also names Bochs (LGPL) directories and FreeDOS/Bochs/vgabios binaries, **none of which are in this tree**. | -- | -- |
| `rtl/pc/ao486/**` (56 files incl. `autogen/`) | Aleksander Osman | BSD-2-Clause: per-file header "Copyright (c) 2014, Aleksander Osman" (the `autogen/*.v` files and `memory/tlb_regs_4way.v` have no header; ao486_MiSTer's LICENSE covers `rtl/`) | no | yes |
| `rtl/pc/soc/{ide,pit,pit_counter,ps2,rtc,vga}.v` | Aleksander Osman | BSD-2-Clause, file headers | no | yes |
| `rtl/pc/soc/{dma,floppy,pic}.v` | Aleksander Osman; Alexey Melnikov (2017-2020) | BSD-2-Clause, file headers | no | yes |
| `rtl/pc/soc/iobus.v` | ao486_MiSTer (no header) | BSD-2-Clause by ao486_MiSTer's LICENSE (`rtl/`) | no | yes |
| `rtl/pc/soc/ide_hps.v` | Alexey Melnikov (2020) | BSD-2-Clause, file header | **modified** (about 29 lines; our note added under the licence) | yes |
| `rtl/pc/soc/sound/sound.v`, `sound_dsp.v` | Aleksander Osman; SB16 support by Alexey Melnikov (2017-2020) | BSD-2-Clause, file headers | `sound.v` **modified** (IRQ 7 default) | yes |
| `rtl/pc/soc/sound/*.qip`, `opl3/opl3.qip` | Quartus file lists | none stated | no | no |
| `rtl/pc/cache/l1_icache.v`, `l2_cache.v` | ao486_MiSTer (no header) | BSD-2-Clause by ao486_MiSTer's LICENSE (`rtl/cache/`) | `l2_cache.v` **modified** (about 181 lines) | yes |
| `rtl/pc/common/simple_fifo.v`, `simple_fifo_mlab.v`, `simple_mult.v`, `simple_ram.v` | Aleksander Osman | BSD-2-Clause, file headers | no | yes |
| `rtl/pc/common/cdc_vector_handshake_continuous.sv`, `synchronizer.sv` | ao486_MiSTer (no header) | BSD-2-Clause by ao486_MiSTer's LICENSE | no | yes |
| `rtl/pc/common/dpram.v` | 486Tang / MiSTer (no header) | no header; at most 486Tang's BSD-3-Clause | **modified** (about 35 lines) | yes |
| `rtl/pc/common/ps2_device.v` | "PS2 device (keyboard or mouse) emulator from MiSTer" (header comment) | no licence in the file; reached us through 486Tang (BSD-3). The MiSTer original's licence is **unknown** (not checked). | no | yes |
| `rtl/pc/common/uart2ps2.v`, `uart_tx_V2.v` | 486Tang (BL616 bridge) | no header; 486Tang BSD-3-Clause | no | **no** (not in `files.f`) |
| `rtl/pc/common/uart_fixed.v` | "(c) fpga4fun.com & KNJN LLC - 2003 to 2016" | **unknown**: no licence in the file | no | **no** |
| `rtl/pc/memory/main_memory.sv` | nand2mario, 7/2025 | 486Tang BSD-3-Clause | no | **no** |
| `rtl/pc/files.f`, `rtl/pc/README.md` | ours | -- | -- | -- |

### 2.2 Sound chips inside the PC core (`rtl/pc/soc/sound/`, untracked)

| Path | Author(s) | Licence (where stated) | Notes |
|---|---|---|---|
| `opl3/*.sv` (29 files) | **Greg Taylor** <gtaylor@sonic.net> (2014-2024), "OPL3 FPGA". Headers also credit Robson Cozendey (the original Java OPL3, 2008) and Steffen Ohrendorf (2012). | **LGPL-3.0-or-later**: every header says "GNU Lesser General Public License ... version 3 ... or (at your option) any later version" | Upstream repository URL not stated in the files. `opl3_pkg.sv` **modified** (CLK_FREQ from `CONSOLE_CLK_HZ`, the divider). Used. |
| `opl3/afifo.v` | **Dan Gisselquist**, Gisselquist Technology, LLC (2023-2024), from his ETH10G project | **GPL-3.0** ("licensed under the terms of the 3rd version of the GNU General Public License"; "License: GPL, v3") | **Used** (`opl3/host_if.sv` instantiates `afifo`). This file makes every PC bitstream GPL-3. We have our own `rtl/async_fifo.v`, which could replace it. |
| `saa1099.sv` | Sorgelig (2016-2019); based on Miguel Angel Rodriguez Jodar's SAA1099.v and Dave Hooper's SAASound | **GPL-2.0-or-later** (header) | **Unused**: its instance in `sound.v` is commented out, and it is not in `files.f`. |

### 2.3 z486 (`rtl/pc/z486/`, untracked; optional `PC_Z486=1` build)

Upstream: nand2mario's **z486_MiSTer**, https://github.com/nand2mario/z486_MiSTer, path `src/z486/`
(the CPU's own repo per its README: https://github.com/nand2mario/z486). `rtl/pc/z486/UPSTREAM`
records commit `825118543e3b00cf8d176804fd2c29ea0759ef83` (2026-10-12).

`LICENSE-SCOPE.md` (copied from upstream) reads: *"The Apache License, Version 2.0 ... applies only
to files ... with the following extensions: `*.sv` and `*.svh`, `*.py`, `*.md`. `ucode.hex` is
excluded from the Apache License 2.0 grant."* Upstream README, "License": *"Copyright 2026
nand2mario. The SystemVerilog, Python, and Markdown files ... are licensed under the Apache License
2.0 ... The recovered microcode image is not covered by this license."* Its Credits section says
the work "builds on Intel microcode disassembly and silicon reverse-engineering by reenigne,
gloriouscow, smartest blob, and Ken Shirriff".

| Path | Licence | Notes |
|---|---|---|
| `LICENSE-z486` | Apache-2.0 text | Keep. |
| `*.sv`, `*.svh`, `x87/*.sv`, `x87/*.svh` (except below) | **Apache-2.0** (LICENSE-SCOPE.md) | **Modified** vs upstream: `address_unit.sv`, `data_access.sv`, `decoder.sv`, `ucode_rom.sv`. Each now opens with a "Modified for fpga-console" notice (Apache 4(b)), and `rtl/pc/z486/README-CHANGES.md` lists the changes. |
| `pla_entry.svh` ("Generated opcode-to-microcode-entry PLA from the **80386 decoder ROM dump**"), `pla_control.svh` ("Generated from the **80386 instruction-layout ROM dump**"), `length_table.svh` (generated from `pla_control.svh`) | Apache-2.0 by extension, **but** self-described as derived from Intel ROM dumps | nand2mario cannot grant rights in Intel's ROM content. Needs a decision: see PUBLISHING_RISKS. |
| `z486_ucode.mem` | **No licence: explicitly excluded** | Byte-identical to upstream `src/z486/ucode.hex` (renamed by us). This is "the recovered microcode image": Intel 80386 microcode, recovered. **Not committed** (`.gitignore`); `tools/pc/fetch_z486.sh` downloads it, and the PLA and x87 ROMs below, from upstream at the pinned commit. |
| `z486_pla_entry_rom.mem`, `z486_pla_group_entry.mem` | **No licence**: `.hex` is not in the scope list | Byte-identical to upstream `pla_entry_rom.hex` / `pla_group_entry.hex`. Decoder ROM data, from the same ROM-dump lineage. |
| `x87/x87_ucode.mem`, `x87/*.mif` | **No licence by the letter** (`.mem`/`.mif` are not in scope) | Byte-identical to upstream. Generated by nand2mario's own `build_x87_*.py` (Apache-2.0), which we do **not** carry. Low practical risk; regenerating from the scripts would put them clearly under Apache. |
| `iobus_adapter.sv`, `pic_inta_bridge.sv` | **unknown** | These come from `z486_MiSTer/src/`, outside `src/z486/` where the LICENSE lives. z486_MiSTer has **no top-level LICENSE**. |
| `files.f`, `UPSTREAM`, `LICENSE-SCOPE.md` | ours / upstream doc | -- |

`sim/pc/z486_ucode.mem`, `sim/pc/z486_pla_*.mem`, `sim/pc/x87_ucode.mem` are copies the Verilator
Makefile makes. The same notes apply.

### 2.4 Other vendored source and data

| Path | State | Upstream / author | Licence (where found) | Obligation |
|---|---|---|---|---|
| `rtl/gba_bios_data.vh` (110 KB, 4096 words) | untracked | **Cult-of-GBA/BIOS**, https://github.com/Cult-of-GBA/BIOS, "Copyright 2020 - 2021 DenSinH and fleroviux", an open replacement GBA BIOS written in ARM assembly | **MIT** (`build/dl/gba-bios/LICENSE`; the .vh header says "MIT") | Verified **not** Nintendo's: the source `bios.bin` md5 is `e2a18f17249a24415ca70d57f40501c8` and the words match. The MIT notice is in `rtl/LICENSE-gba-bios`. |
| `rtl/n64_rdp_blut.v` (generated), `tools/n64/n64rdp.py`, `tools/n64/n64rdptables.py`; behaviour in `rtl/n64_rdp2.v`, `rtl/n64_rdp_persp.v` | tracked | **parallel-RDP**, Hans-Kristian Arntzen (Themaister), https://github.com/Themaister/parallel-rdp | **MIT**, quoted in full in `tools/n64/n64rdp.py` ("Copyright (c) 2020 Themaister"); `n64_rdp_blut.v` header: "luts.hpp blender_lut, MIT" | Keep the notice. The table in `n64_rdp_blut.v` carries only a one-line credit; point it to the full text. |
| `esp32/console/qrgen.c`, `qrgen.h` | tracked | **ricmoo/QRCode**, Richard Moore (https://github.com/ricmoo/QRCode), derived from Project Nayuki's library | **MIT** (file headers, full text) | Keep the headers. |
| `esp32/console/cdrom.h` | untracked | Port of **Main_MiSTer** `ide.cpp` / `ide_cdrom.cpp`, https://github.com/MiSTer-devel/Main_MiSTer, "Copyright (C) MiSTer-devel and Alexey Melnikov" | **GPL-3.0** (file header: "this file is under the same licence"; `build/dl/pc/Main_MiSTer/LICENSE` is GPL v3) | See section 1: the ESP32 console firmware becomes GPL-3. Also compiled by `sim/pc/main.cpp` (untracked). |
| `tools/menu/fonts/Nunito.ttf`, `OFL.txt` | untracked | **Nunito**, "Copyright 2014 The Nunito Project Authors (https://github.com/googlefonts/nunito)" | **OFL-1.1** (`OFL.txt`) | Keep `OFL.txt` with it. `esp32/console/gfx_font.h` (412 KB, untracked) is a bitmap rendering of it, and its header credits OFL. |
| `rtl/osd_font.v`, `rtl/osd_glyphs.v`, `sim/osd_font_ref.hex` | tracked | **font8x8_basic**, Daniel Hepper, https://github.com/dhepper/font8x8, from the IBM VGA fonts | **Public domain** (per `tools/gen_osd_font.py`, which fetches the header into `build/`) | None. |
| `boards/qmtech_a100t/mig_a100t.prj` | tracked | Generated by Xilinx's **MIG** 2.3 wizard (file header) | Xilinx tool output; the IP itself is generated into `build/` by `tools/mig.tcl` and is **not** in the repo | The Vivado/IP licence lets you use generated IP in Xilinx devices. The `.prj` (a pin/config list) is fine to publish. |
| `boards/qmtech_a100t/*.xdc`, `HEADERS.md` | tracked | Our own, transcribed from QMTECH's schematic `QMTECH_XC7A75T_100T_200T-CORE-BOARD-V01-20210109.pdf` | ours (factual pin data) | -- |
| `rtl/ps1_spu_gauss.v` | tracked | The SPU's 512-entry Gaussian table, "from the table in psx-spx, DuckStation spu.cpp and PSX_MiSTer spu_gauss.vhd" (cross-checked) | Hardware constants (factual data) | Low risk; credited. |
| `rtl/n64_rsp_tables.v`, `rtl/ym_tables.vh`, `rtl/nes_palette*.v`, A26 NTSC palette in `sim/tb_a26.v` | tracked | Generated by our scripts from formulas / measured palettes | ours (factual) | -- |

### 2.5 Own work checked and found original

Every CPU and chip core outside `rtl/pc/` has a project header. None carries a third-party
copyright or licence, and none matched an upstream clone. Several state their sources (data
sheets, Fullsnes, Pan Docs, psx-spx, the Stella guide, or ares behaviour through our Python models):
`cpu6502.v` (NES 6502), `z80.v` + `wip/z80.v`, `m68k.v`, `w65816.v`, `spc700.v`, `r3000.v`,
`vr4300.v`, `vr4300_fpu.v`, `gb_cpu.v` (SM83), `arm7tdmi.v`, `huc6280.v`, `ym2612.v`, `psg.v`,
`snes_dsp.v`, the PS1 GTE/GPU/SPU/MDEC/CD-ROM, the N64 RSP/RDP, `gba_*`, `pce_*`, `a26_*`, `hdmi_*`,
`ddr3_mem.v`, `async_fifo.v`.

Firmware stand-ins are our own, with no console maker's code:
- `rtl/n64_boot_rom.v`, generated by `tools/n64/n64bootrom.py`: "our own, in place of the PIF ROM and the cartridge's IPL3".
- The SNES SPC700 boot ROM in `rtl/snes_apu.v` / `tools/snes/apu.py`: "ours ... not Nintendo's". Its first 20 bytes coincide with Nintendo's IPL, because the upload handshake ($AA/$BB/$CC) dictates them. It diverges after that.
- The Game Boy, Mega Drive, Master System, PC Engine and Atari 2600 cores have no boot ROM.

---

## 3. Projects used as behavioural references only (no code copied, per the sources)

These shaped behaviour, and our headers name them. Copying code from a non-permissive one would
change the picture, so the claims are recorded here.

| Reference | Licence | Where cited | Note |
|---|---|---|---|
| **ares** (https://github.com/ares-emulator/ares) | ISC | `tools/n64/n64model.py`, `n64rsp.py`, `n64fpu.py`, `n64pif.py`; `rtl/vr4300*.v`, `n64_rsp.v`, `n64_rdp*.v`, `n64_pif.v` | Permissive; fine even where closely followed. Keep the credit. |
| **DuckStation** (https://github.com/stenzek/duckstation) | **CC-BY-NC-ND-4.0** today (GPL-3 before 2024); `docs/MDEC_NOTES.md` records "CC-BY-NC-ND: behaviour only" | `rtl/ps1_gpu.v`, `ps1_cdrom.v`, `ps1_dma.v`, `tools/ps1/spu_ref.py`, **`pc/cdaudio.py` and `esp32/console/xa.h`** | `cdaudio.py` says its XA decoder works "exactly as DuckStation does (CDROM::DecodeXAADPCMChunks, ResampleXAADPCM ...)". `xa.h` is "a line-for-line port of pc/cdaudio.py's XaDecoder". If any of this was transliterated from DuckStation source rather than written from psx-spx, ND forbids it. **Confirm before publishing.** The filter coefficients and zigzag tables themselves are hardware constants documented in psx-spx. |
| **Mednafen / Beetle-PSX** | GPL-2.0 | `tools/ps1/spu_ref.py`, `pc/cdaudio.py` (18.9 kHz table), `docs/MDEC_NOTES.md`, `tools/pce/mednafen_shot.py` (runs it as an external program) | Behaviour only. |
| **PSX_MiSTer** (https://github.com/MiSTer-devel/PSX_MiSTer) | GPL | `rtl/ps1_gpu.v`, `ps1_dma.v`, `ps1_icache.v`, `ps1_spu_ram.v`, `docs/MDEC_NOTES.md` ("GPL: behaviour only") | Behaviour only. |
| **hdl-util/hdmi** | MIT / Apache-2.0 | `rtl/hdmi_tx.v` ("checked against") | Behaviour only. |
| pgate1, Laxer3a PS-GPU, cen64, jPSXdec, libdragon | various | comments, docs | Behaviour only. |
| psx-spx / Fullsnes (nocash), Pan Docs, Stella Programmer's Guide, n64brew, DVI 1.0 spec | documentation | throughout | -- |

---

## 4. External dependencies: fetched or installed, never committed

| Dependency | Licence | How it arrives | Obligation when you distribute a binary built with it |
|---|---|---|---|
| **Bluepad32** | Apache-2.0 (per `esp32/README.md`, `pads.h`) | Arduino platform `esp32-bluepad32`, T8 builds only (`__has_include(<Bluepad32.h>)`) | Apache notice. |
| **BTstack** (under Bluepad32) | "Free for non-commercial use only" (per `esp32/README.md`); commercial use needs a BlueKitchen licence | as above | **Conflicts with GPL-3 `cdrom.h`** in the same binary; see section 1. |
| **arduino-esp32** core + ESP-IDF | LGPL-2.1 (Arduino core), Apache-2.0 (ESP-IDF) | Arduino board package | LGPL static linking: let recipients relink (provide objects or the source). |
| Arduino libraries `SD`, `SD_MMC`, `SPI`, `Preferences` | part of arduino-esp32 | as above | as above |
| `arduino-cli` | GPL-3.0 (upstream) | `tools/arduino/` (**ignored**) | Not redistributed. |
| **Bochs BIOS** (`boot0.rom`) and **LGPL VGA BIOS** (`boot1.rom`) | LGPL (per ao486_MiSTer LICENSE and `esp32/console/pc.h`: "Bochs's, LGPL: in 486Tang's tools/") | Copied by the user from 486Tang's `tools/` to the SD card `/pc/` | Not in the repo. Shipping them on a card image requires their source / notices. |
| **FreeDOS** kernel 2043 + FreeCOM (GPL-2), HIMEMX (GPL), CuteMouse (GPL), **UDVD2** (Jack Ellis, "free with sources"), **SHSUCDX** (Jason Hood) | as noted in `tools/pc/mkdisk.sh` comments | Downloaded to `build/dl/fdos/` (ignored). `tools/pc/mkdisk.sh` / `addgame.py` assemble them into disk images in `build/pc/` (ignored) | Not in the repo. Distributing a built disk image means GPL source offers for the FreeDOS parts. |
| `syslinux` `mbr.bin` | GPL-2.0 | from the WSL host (`/usr/lib/syslinux/mbr/mbr.bin`), written into disk images | as above |
| Game content (Doom, Rayman, TTD, eXoDOS packs) | commercial / shareware | `build/dl/` (ignored) | Never commit. |
| **RetroPie es-theme-carbon** art (console logos, controller drawings) | not determined here; the logos are console makers' trademarks | `tools/menu/mklogos.py` downloads them at run time to `build/menu_art` | Not in the repo, by design (the script says so). |
| font8x8 header | public domain | `tools/gen_osd_font.py` (curl into `build/`) | -- |
| Cult-of-GBA BIOS clone | MIT | `build/dl/gba-bios` | Its output is the tracked-to-be `rtl/gba_bios_data.vh` (2.4). |
| Test suites: SingleStepTests (sm83, 65x02, ARM7TDMI, spc700, 65816), krom / PeterLemon N64 + SNES, blargg, JaCzekanski ps1-tests, nemu64-test, cgb-acid2, Tonc, gba-tests, arm7tests, PCE_Blox | various | `build/dl/`, `sim/roms/` (both **ignored**) | Not redistributed. |
| Python: flask, numpy, miniaudio (`requirements.txt`); Pillow; **PyMuPDF** (`tools/menu/mklogos.py`) | BSD / MIT-style; **PyMuPDF is AGPL-3.0** (or commercial) | `pip` | Only run locally; does not affect the repo's licence. Note PyMuPDF if the tool is ever shipped as a service. |
| Vivado, Verilator, nasm, mtools, WSL | vendor / GPL | installed tools | -- |

---

## 5. Attribution file to ship with binaries (checklist)

Any release zip, bitstream set or firmware image should carry this file, or a NOTICE derived from
it, with these texts:
- BSD-2 (Aleksander Osman; Alexey Melnikov): `rtl/pc/LICENSE-ao486_MiSTer`
- BSD-3 (nand2mario): `rtl/pc/LICENSE-486tang`
- Apache-2.0 (z486): `rtl/pc/z486/LICENSE-z486` (only for PC_Z486 images)
- LGPL-3.0 (OPL3) and GPL-3.0 (afifo, cdrom.h): the full licence texts, with a written source offer
- MIT: Cult-of-GBA BIOS (DenSinH, fleroviux), parallel-RDP (Themaister), QRCode (Richard Moore, Project Nayuki)
- OFL-1.1: Nunito
- Apache-2.0: Bluepad32 (T8 firmware)
