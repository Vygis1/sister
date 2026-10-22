# The consoles

How each machine is built, and how it is checked. (The stand-alone console's
user guide is [GUIDE.md](GUIDE.md).)

### NES — `rtl/nes.v`, `cpu6502.v`, `ppu.v`, `apu.v`, `mapper.v`

- **6502:** cycle-accurate, NMOS quirks included, and without decimal mode, as
  on the 2A03. It passes Klaus Dormann's functional test and matches the nestest
  log for all 8,991 logged instructions, including the undocumented opcodes.
- **2C02 PPU:** background, sprites, sprite-zero hit and the real frame
  geometry, with pixels shown 8:7 wide as on a television.
- **APU:** five channels and the non-linear mixer.
- **Mappers:** NROM (0), MMC1 (1), UxROM (2) and MMC3 (4), including MMC3's
  A12 scanline counter that games use for split screens.

### Master System — `rtl/sms.v`, `z80.v`, `vdp.v`, `psg.v`

- **Z80:** passes ZEXDOC and ZEXALL on the board.
- **VDP:** background, sprites and interrupts. The sprite fetch is reordered so
  the first tile of each line is ready in time.
- **SN76489** sound, and the Sega mapper.

### Mega Drive — `rtl/md_console.v`, `m68k.v`, `md_vdp.v`, `md_sound.v`, `ym2612.v`

- **68000:** checked by a self-checking test program assembled in this tree
  (`tools/md/m68kasm.py`), which covers results, condition codes and addressing
  modes separately.
- **VDP:** planes, sprites and all three DMA modes.
- **Z80 sound CPU:** with its bus handover and bank register.
- **Sound chips:** the SN76489, and a YM2612 FM chip computed in decibels, as
  the real chip is.
- **Cartridges** are read from DDR3 through a cache, so games of up to 4 MB fit.

### Game Gear — `rtl/sms.v` with `GG=1`

- The Master System core, with three Game Gear differences: the 12-bit palette (CRAM written a
  byte pair at a time), the START button on port 00h, and stereo through port 06h.
- **LCD:** the 160 x 144 window (rows 24-167, columns 48-207 of the VDP's picture), shown
  tripled.

### Game Boy / Game Boy Color — `rtl/gb_top.v`, `gb_cpu.v`, `gb_ppu.v`, `gb_apu.v`

- **SM83:** passes all 500,000 SingleStepTests cases, blargg's `cpu_instrs` and
  `instr_timing`.
- **PPU:** dmg-acid2 and cgb-acid2 pass pixel for pixel in simulation; cgb-acid2 also passes
  on the board.
- **Color:** VRAM banks, tile attributes, palettes, OAM priority, double speed and HDMA. The
  cartridge header picks the mode.
- **Cartridges:** MBC1, MBC3 and MBC5, read from DDR3 through a cache.

### Game Boy Advance — `rtl/gba_top.v`, `arm7tdmi.v`, `gba_ppu.v`, `gba_snd.v`, `gba_ewram.v`, `gba_rtc.v`

- **ARM7TDMI:** one instruction at a time with the pipeline modelled. It passes 2,204,782 of
  the 2,204,858 SingleStepTests cases; the rest are the reference's multiply-flag artefact.
- **Bus:** wait states and prefetch at the console's own cycle timing; EWRAM and the cartridge
  in DDR3.
- **Picture:** text and affine backgrounds, bitmap modes, sprites, windows, blending and mosaic,
  checked pixel for pixel against a reference renderer (`tools/gba/ppuref.py`) on Tonc's demos.
- **Sound:** the Game Boy's four channels plus the two sample FIFOs. Also DMA, timers and the
  cartridge clock (Seiko S-3511).
- **BIOS:** the open Cult-of-GBA BIOS is built in (MIT, `rtl/LICENSE-gba-bios`). A real one in
  `/bios/gba_bios.bin` is used instead when present.

### PC Engine — `rtl/pce_top.v`, `huc6280.v`, `pce_vdc.v`, `pce_vce.v`, `pce_psg.v`

- **HuC6280:** passes the full 65C02 single-step suite, plus a test card for Hudson's own
  instructions, the MMU, the timer and the interrupts.
- **HuC6270 VDC** (pixel-exact directed test), **HuC6260 VCE**, the six-channel **PSG**, and
  a two-port multitap.

### Atari 2600 — `rtl/a26_top.v`, `a26_tia.v`, `a26_riot.v`

- **6507:** the NES's 6502 with RDY.
- **TIA** and **RIOT**.
- **Bank switching:** 2K to 32K, including F8/F6/F4, Super Chip, FE, E0, 3F and FA. A scheme
  named in the file name wins.

### Super NES — `rtl/snes_top.v`, `w65816.v`, `snes_cpu.v`, `snes_ppu.v`, `snes_apu.v`, `spc700.v`, `snes_dsp.v`

- **65816 and SPC700:** bus-cycle exact against over 750,000 recorded SingleStepTests cases.
  gilyon's CPU and SPC test ROMs pass on the board.
- **PPU:** modes 0-7. Hi-res modes are shown 256 wide.
- **DSP:** eight voices, echo and the Gaussian filter.
- **Cartridges:** LoROM and HiROM up to 6 MB. No enhancement chips.

### Nintendo 64 — `rtl/n64_top.v`, `vr4300.v`, `vr4300_fpu.v`, `n64_rsp.v`, `n64_rdp*.v`, `n64_vid.v`

Covered in [N64.md](N64.md).

### DOS PC — `rtl/pc_top.v`, `pc_*.v`, `rtl/pc/` (third-party)

The one machine **not** written from scratch for this project. It is nand2mario's 486Tang (a
port of ao486_MiSTer: Aleksander Osman's ao486 CPU and chipset), with MiSTer's L2 cache, IDE
code and Sound Blaster, and Greg Taylor's OPL3. Every part's licence is listed in
[THIRD_PARTY.md](THIRD_PARTY.md). Our own parts:

- **`pc_top.v`:** the system (CPU, L2 cache, chipset, VGA, sound, IDE) on the console's DDR3
  (`pc_ddr64.v`), at 71.4 MHz.
- **`pc_fb.v`:** the VGA's picture out of DDR3, scaled to 640 x 480. VESA SVGA modes (8-bit
  through the palette, 16-bit RGB565) come from the framebuffer the L2 cache writes.
- **`pc_disk.v`:** the IDE hard disk, served by the ESP32 from an image on the SD card, with
  read-ahead.
- **CD-ROM:** an ATAPI drive on the second IDE channel. The ESP32 serves its sectors from a
  `.cue` / `.bin` image (`esp32/console/cdrom.h`, a port of MiSTer's CD-ROM code). CD audio
  plays through `pc_cdda.v`.
- **Mouse and keyboard:** the pad, mapped per game (`esp32/console/pc.h`).
- **The BIOS load** (`pc_ddr64.v`): the ESP32's words gathered four to a DDR3 line behind a queue,
  so none is lost when DDR3 is slow; a lost word would raise ctrl `0x706C`.

### PlayStation — `rtl/ps1_*.v`, `r3000.v`

Covered in [PLAYSTATION.md](PLAYSTATION.md).
