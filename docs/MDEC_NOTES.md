# PS1 MDEC (motion decoder): implementation notes

Clean-room notes for the RTL. Everything is in my own words, describing behaviour.
No emulator code was copied. Where sources disagree, every candidate is listed
and tagged with where it came from:
- [SPX] psx-spx (nocash), the public documentation
- [MF] Mednafen / Beetle-PSX `mdec.c`, GPL: behaviour only
- [DS] DuckStation `mdec.cpp`, CC-BY-NC-ND: behaviour only
- [MR] PSX_MiSTer `mdec.vhd`, GPL: behaviour only
- [DECAP] psxdev.ru die-trace thread

**Status of knowledge (read first).** Nobody has published a bit-exact hardware
IDCT. nocash wrote that he could not reproduce the IDCT without rounding errors.
The decap shows the internal widths (section 4.4). jPSXdec states in its source
that its "PSX" IDCT does not match the chip either. The most hardware-tested
model is [MF]: Mednafen's author tested MDEC on real hardware, and DuckStation's
current "new" routines follow it. **Recommendation: implement [MF] as the
reference (sections 3.3, 4.2, 5.1), and keep the alternatives behind parameters.**
I ran 300 random blocks through Python models: [MF] vs [DS-new] disagree on 3.6% of
pixels (max ±1), [MF] vs [SPX]/[DS-old] on 12% (max ±2), and [MF] vs [MR] on 50%
(max ±2, because [MR] truncates). Without a capture from a real console, ±1 LSB
cannot be settled.

---------------------------------------------------------------------------
## 1. Registers

### 1F801820h write: command / parameter FIFO (MDEC0)
32-bit words go into the 32-word data-in FIFO. A word that arrives while the MDEC is
idle is a command. Words that arrive during a command are its parameters. DMA0
writes into the same FIFO. Within a word, the **low halfword is consumed first**.

### 1F801820h read: data-out FIFO
This pops one word from the 32-word data-out FIFO. If the FIFO is empty the result
is garbage ([MR] and [DS] return FFFFFFFFh). Read by the CPU, the data always
comes out in 8x8-pixel block order (see section 6). The 16x16 re-ordering is done
by DMA1, not by the MDEC.

### 1F801824h read: status (MDEC1)
| bit | name | meaning / when it changes |
|---|---|---|
| 31 | OUT_EMPTY | 1 = data-out FIFO empty |
| 30 | IN_FULL | 1 = data-in FIFO full ([SPX]: "or last word received"; [MF]/[DS]/[MR]: FIFO full only) |
| 29 | BUSY | 1 from when the command word is taken until the command has consumed all its parameters and the last decoded data has been pushed. 0 when idle. [MR]: 1 whenever the receiver is not idle |
| 28 | DREQ0 | data-in request. Only with ctrl bit 30 = 1. [MF]: also requires the in-FIFO to be completely empty (32 words free) AND a command to be expecting more parameters. [DS]/[MR]: enable AND room for a 32-word block |
| 27 | DREQ1 | data-out request. Only with ctrl bit 29 = 1. [MF]: out-FIFO holds 32 or more words. [SPX]: set when a block is available, and drops after the first few words are read, though the block can still be read until OUT_EMPTY |
| 26-25 | depth | copy of command bits 28-27 (0 = 4-bit, 1 = 8-bit, 2 = 24-bit, 3 = 15-bit) |
| 24 | signed | copy of command bit 26 |
| 23 | bit15 | copy of command bit 25 |
| 22-19 | - | always 0 |
| 18-16 | current block | 0-3 = Y1-Y4, 4 = Cr, 5 = Cb. Mono is always 4. While the out-FIFO holds data, this is the block being OUTPUT (DMA1 uses it to re-order). While it is empty, it is the block being decoded (Cr, Cb, Y1..Y4) |
| 15-0 | words remaining - 1 | for MDEC(1): parameter words still expected, minus 1. FFFFh = none. Counts down as each 32-bit word is consumed |

Bits 26-23 are loaded from command bits 28-25 for **every** command word, MDEC(2),
(3), (0) and (4-7) included.

### 1F801824h write: control / reset
- bit 31 = reset. It aborts any command, flushes both FIFOs, clears the decoder
  state (coefficient index, block counter, q_scale), and makes status read
  **80040000h** (OUT_EMPTY plus current block 4; the low field reads 0000h, not
  FFFFh). It does **not** clear the quant tables or the scale table ([SPX], [MF]).
- bit 30 = enable data-in request (DMA0 and status bit 28).
- bit 29 = enable data-out request (DMA1 and status bit 27).
- bits 28-0 are unused.
Every write to this register reloads bits 30 and 29, whatever bit 31 is. [MR]
fixed real games with this: Slam Dragon (soft reset from a CPU write) and the CTR
track preview videos (the reset command).

---------------------------------------------------------------------------
## 2. Commands (bits 31-29 of the command word)

**MDEC(1): decode macroblocks.** bits 28-27 = depth, bit 26 = signed output,
bit 25 = set bit 15 (15-bit output only), bits 24-16 = unused, bits 15-0 = N, the
number of 32-bit parameter words (2N RLE halfwords). Decoding goes on across as
many macroblocks as the data holds. The decoder state is reset at the start of
each MDEC(1): coefficient index 0, next block = Cr (colour) or Y (mono). The
command ends when N words have been consumed, even in the middle of a block.
Depth 0/1 decodes **mono** (one Y block per macroblock, luma table). Depth 2/3
decodes **colour** (six blocks).
Command words this layout gives: 15-bit is 38000000h|N, or 3A000000h|N with bit 15
set. 24-bit is 30000000h|N.

**MDEC(2): set quant tables.** bit 0 = colour. 16 words (64 bytes) follow for the
luma table (used for Y), then, only if bit 0 = 1, 16 more for the chroma table
(used for Cr and Cb). Byte order: byte 0 = bits 7-0 of the first word. The
entries are unsigned 8-bit and are indexed by the **zigzag sequence number k** of
the coefficient, not by its position in the matrix. The command word is normally
40000001h.

**MDEC(3): set scale (IDCT) table.** 32 words follow: 64 signed halfwords, low
halfword first. The command word is normally 60000000h. Upload index i =
row i>>3, column i&7 of the table in section 4.1.

**MDEC(0) and MDEC(4-7): no function.** They copy bits 28-25 to status 26-23 and
bits 15-0 to status 15-0 (without the "minus 1"), and expect no parameters [SPX].
Implementations differ here: [MF] consumes nothing. [DS] swallows N following
words. [MR] keeps the FIFO intact, a fix for Formula 1 Rev1 ("don't clear the
FIFO on invalid opcodes, so DMA stops sending"). Follow [SPX]/[MF]: take the one
word and do nothing else.

Neither table exists until the game uploads it. A game that never sends MDEC(3)
decodes flat mid-grey [SPX]. The tables are kept across resets. Power-on value: 0.

Standard quant table (in zigzag order; it is the MPEG-1 intra matrix with entry
0 = 2 instead of 8) [SPX]:
`02 10 10 13 10 13 16 16 16 16 16 16 1A 18 1A 1B 1B 1B 1A 1A 1A 1A 1B 1B 1B 1D 1D 1D 22 22 22 1D`
`1D 1D 1B 1B 1D 1D 20 20 22 22 25 26 25 23 23 22 23 26 26 28 28 28 30 30 2E 2E 38 38 3A 45 45 53`

---------------------------------------------------------------------------
## 3. Input: run-length halfwords

### 3.1 Halfword format
- First halfword of a block (DC): bits 15-10 = q_scale (unsigned 6-bit), bits 9-0
  = DC (signed 10-bit). q_scale is latched for the whole block.
- Each next halfword (AC): bits 15-10 = run (zeros skipped), bits 9-0 = level
  (signed 10-bit). Then k = k + run + 1. If k <= 63 the coefficient is stored at
  sequence index k. If k > 63 the block ends and the level is discarded.
- FE00h (run 63, level 0) is end-of-block: it always pushes k past 63. **FE00h in
  the DC slot (start of a block) is skipped as padding**, so any number of FE00h
  may sit between blocks or at the end of the data. Note that this makes the DC
  value q = 63, DC = -512 impossible to send.
- An EOB is not needed once k reaches 63. The block ends as soon as coefficient 63
  has been written, and the next halfword is the DC of the next block.
- The coefficient array is zeroed at the start of each block.

### 3.2 Block order
Colour (depth 2/3): **Cr, Cb, Y1, Y2, Y3, Y4**. Cr and Cb use the chroma table, Y1-4
the luma table. Y1 = top left, Y2 = top right, Y3 = bottom left, Y4 = bottom right
of the 16x16 macroblock. (nocash's own copy of the pseudocode has the Y2/Y3
offsets swapped; its comments, consoledev.net and all three emulators agree on
TL, TR, BL, BR.)
Mono (depth 0/1): a single 8x8 Y block, luma table.

### 3.3 Dequantisation, [MF] (recommended)
This produces a 15-bit IDCT input c with 4 fraction bits. In 12-bit terms it is
c = 8·(2p − sgn(level)), which matches the 12-bit IDCT input that [DECAP] saw.
- DC (k = 0): q = qt[0]. **q_scale is not used for DC.** p = DC·q.
- AC (k >= 1): q = q_scale·qt[k]. p = floor(level·q / 8) (arithmetic shift right by 3).
- If q ≠ 0: c = 16·p − 8 if level > 0; c = 16·p + 8 if level < 0; c = 0 if level = 0.
  (A positive level whose p is 0 gives c = −8.)
- If q = 0, the special mode: c = 32·level (that is level·2·16, with no ±8).
- Saturate c to [−4000h, +3FFFh].
- Store c at matrix position zagzig[k] (section 3.4), in **both** modes.

[SPX] differs:
- Its 11-bit domain uses v = DC·qt[0] for DC and v = (level·qt[k]·q_scale + 4)/8
  for AC, saturated to [−400h, 3FFh].
- The special mode is chosen by **q_scale = 0** (not by q = 0). It gives v = 2·level
  and stores it at index k **without zigzag**. [MR] does the same.
- nocash later wrote in the decap thread that he had removed the +4 rounding,
  which matches [MF]'s floor.
- The two disagree only in edge cases: q_scale = 0, or a qt entry of 0. Real video
  always has q_scale ≥ 1 and nonzero tables.

### 3.4 Zigzag
zagzig[k] = row-major matrix position (row = vertical frequency, column =
horizontal frequency) of sequence index k. This is the standard JPEG order; k = 1
is horizontal frequency 1.
```
k 0-15 : 0 1 8 16 9 2 3 10 17 24 32 25 18 11 4 5
k16-31 : 12 19 26 33 40 48 41 34 27 20 13 6 7 14 21 28
k32-47 : 35 42 49 56 57 50 43 36 29 22 15 23 30 37 44 51
k48-63 : 58 59 52 45 38 31 39 46 53 60 61 54 47 55 62 63
```
The inverse, zigzag[pos] = k ([SPX] prints it this way):
`0 1 5 6 14 15 27 28 / 2 4 7 13 16 26 29 42 / 3 8 12 17 25 30 41 43 / 9 11 18 24 31 40 44 53 /`
`10 19 23 32 39 45 52 54 / 20 22 33 38 46 51 55 60 / 21 34 37 47 50 56 59 61 / 35 36 48 49 57 58 62 63`

---------------------------------------------------------------------------
## 4. IDCT

### 4.1 Scale table, as the game's library uploads it (T[f][p]: row f = frequency, column p = pixel)
```
f0: 5A82 5A82 5A82 5A82 5A82 5A82 5A82 5A82
f1: 7D8A 6A6D 471C 18F8 E707 B8E3 9592 8275
f2: 7641 30FB CF04 89BE 89BE CF04 30FB 7641
f3: 6A6D E707 8275 B8E3 471C 7D8A 18F8 9592
f4: 5A82 A57D A57D 5A82 5A82 A57D A57D 5A82
f5: 471C 8275 18F8 6A6D 9592 E707 7D8A B8E3
f6: 30FB 89BE 7641 CF04 CF04 7641 89BE 30FB
f7: 18F8 B8E3 6A6D 8275 7D8A 9592 471C E707
```
T[f][p] = round(8000h · C_f · cos((2p+1)fπ/16)), with C_0 = 1/√2 and C_f = 1
otherwise. So 5A82h = 23170 = 32768/√2, 7D8Ah = 32138 = 32768·cos(π/16), and
E707h = −6393 = 32768·cos(9π/16). The pattern is ±s0..s7 [SPX]. It is not built into the BIOS: the game's library uploads it (see
section 2). [SPX] and [DECAP] say the hardware keeps only the **upper 13 bits** of
each value (T >> 3, arithmetic), stored as 32 entries of 26 bits.

### 4.2 Two passes, [MF] (recommended; [DS-new] is the same except where noted)
Let M[f][p] = T[f][p] >> 3 (signed 13-bit; 5A82h → 2896, 7D8Ah → 4017).
Let C[v][u] be the dequantised block (v = vertical frequency row, u = horizontal
frequency column).
1. **Pass 1, vertical, per frequency column u:** for each pixel row y,
   t[y][u] = (Σ_{v=0..7} C[v][u]·M[v][y] + 4000h) >> 15 (arithmetic, so it
   rounds half up). [MF] keeps t as int16.
2. **Pass 2, horizontal, per pixel row y:** for each pixel column x,
   s = (Σ_{u=0..7} t[y][u]·M[u][x] + 4000h) >> 15.
3. **Output:** take the low 9 bits of s as a signed 9-bit number (wrap!), then
   clamp to [−128, 127]. Every block, Y, Cr and Cb alike, is kept as **signed
   8-bit** after this.
- [DS-new] is identical, but uses the full 16-bit T in both passes with
  (Σ + 20000h) >> 18.
- **Order matters for bit-exactness:** vertical pass first, rounding between the
  passes. The hardware does "column by column" ([SPX]: the matrices are
  diagonally mirrored, twice).
- Sanity check: with only DC, the output ≈ C[0][0]/16 · 2896² / 2^30 ≈ p/8, which
  is the JPEG DC gain.

### 4.3 Alternatives seen
- [SPX] / [DS-old]: 11-bit v, full 16-bit T. Pass 1 sums are kept at full
  precision (no shift). Pass 2: s = Σ t·T over 2^32, rounded by adding bit 31.
  Then sign-extend 9 bits and clamp.
  nocash's older form: each pass sums src·(T/8), then (sum + 0FFFh)/2000h (round
  up only above .5). He calls this "roughly like the hardware, not perfect".
- [MR]: like [DS-old], but truncates (s >> 32 with no rounding) and clamps without
  the 9-bit wrap. In my model test it is the furthest from [MF], so do not use it
  as the reference.

### 4.4 What the die shows [DECAP] (unconfirmed numerics, use to guide widths)
- There are two identical multiply-accumulate units, one per pass, pipelined. Pass 2
  starts as soon as the first 8 sums of pass 1 exist. Between them sits a 16x13-bit
  double buffer (two banks of 8).
- Pass 1: 12-bit coefficient × 13-bit table, a 17-bit accumulator (product bits
  6-0 dropped, carry-only), and the upper 13 bits are kept.
- Pass 2: 13-bit × **upper 12 bits** of the table, a 17-bit accumulator, and the
  upper 10 bits go out. The last stage is a signed divide by 2, rounding up
  ((x+1)>>1 after a 10-bit mask), clamped to [−128, 127].
- The multiplier is radix-4 Booth (6 partial products for 12 bits). It does one
  multiply-accumulate per clock, so 8 clocks per output value.
- There is a 768-byte SRAM, believed to be the 16x16x24-bit output buffer.
- Using these rules nocash matched every qscale = 0 case, but not qscale > 0.

---------------------------------------------------------------------------
## 5. Colour conversion and output words

### 5.1 YCbCr → RGB, [MF] (recommended)
Inputs Y, Cb, Cr are the signed 8-bit block values. Chroma is nearest-neighbour
upsampled: pixel (X, Y) of the 16x16 macroblock uses Cr/Cb[Y>>1][X>>1], with no
interpolation.
- R = Y + ((359·Cr + 80h) >> 8)
- G = Y + ((((−88·Cb) AND NOT 1Fh) + ((−183·Cr) AND NOT 07h) + 80h) >> 8)
  (the AND masks drop low bits of the two-complement products before they are added)
- B = Y + ((454·Cb + 80h) >> 8)
- Then, for each channel: take the low 9 bits as signed (wrap), and clamp to [−128, 127].
- The coefficients are 1.402, −0.3437, −0.7148 and 1.7734 in 8 fraction bits.
  AmiDog wrote that he verified all 16.8M Y/Cb/Cr inputs on hardware with
  5744/−1408/−2928/7264 over 4096, which is the same ×16, "but with overflow edge
  cases". [MF] notes that green is still slightly off when Cb and Cr are both
  nonzero.
- **9-bit wrap quirk:** [MF], [SPX] and [DS] wrap at 9 bits, so for example Y = 127,
  Cb = 127 gives B = 352, which becomes −160 and clamps to −128 (dark).
  [MR] instead clamps at full width and floors without the +80h. Its commit log
  says this fixed "occasional wrong colour dots" in Star Wars: The Phantom Menace.
  That is a real hint the hardware may **not** wrap here. Make this a parameter.
  The mono path's 9-bit wrap ([SPX] y_to_mono) was hardware-tested by nocash.

### 5.2 Signed and unsigned
Unsigned output (bit 26 = 0) adds 128 to each 8-bit channel, which is the same
as XOR 80h. Signed output (bit 26 = 1) emits the signed byte as it is.

### 5.3 Output word formats (little-endian; first pixel in the low bits)
- **24-bit (depth 2):** bytes R, G, B per pixel, packed with no gaps. 4 pixels =
  3 words: w0 = R0 G0 B0 R1, w1 = G1 B1 R2 G2, w2 = B2 R3 G3 B3 (low byte
  first). 8 px = 6 words. **48 words per 8x8 block, 192 per macroblock.**
- **15-bit (depth 3):** each channel = min(31, (u8 + 4) >> 3), rounded from the
  UNSIGNED value. Halfword = R | G<<5 | B<<10 | bit25<<15. Two pixels per word,
  the left pixel in bits 15-0. 32 words per block, 128 per macroblock.
  - Signed 15-bit = the unsigned result XOR 4210h, which flips the top bit of
    each 5-bit field [MF].
  - [MR] rounds the same way. [DS-old] truncates.
- **8-bit mono (depth 1):** 4 pixels per word, the first in bits 7-0. 16 words per block.
- **4-bit mono (depth 0)**, [MF]: n = min(127, Y + 8) taken as a signed byte, and
  the nibble is its high nibble (n >> 4, signed 4-bit). Unsigned = XOR 8. 8 pixels
  per word, the first in bits 3-0. 8 words per block.
  [DS] and [MR] use (unsigned byte) >> 4 with no +8.

---------------------------------------------------------------------------
## 6. Output order, DMA and FIFOs

**The MDEC emits the macroblock one 8x8 Y block at a time** (Y1, Y2, Y3, Y4; in
each block, row 0 left to right, then row 1, and so on). Each colour block is
output as soon as its Y block is decoded, which is why Cr and Cb come first.
Mono emits its one 8x8 block, and no re-ordering is needed.

**DMA1 does the 8x8 → 16x16 re-ordering**, using status bits 18-16. The effect, [MF]:
- Let W = words per 8-pixel half-row (6 for 24-bit, 4 for 15-bit, 0 = no
  re-order for mono).
- Let R = the half-row counter (0-31, one step every W words, from the start of
  the command).
- For each word DMA1 writes, the destination = the linear DMA address + 4·off,
  where off = (R AND 7)·W, minus 7·W more if R bit 3 is set.
- Result: rows of the 16x16 macroblock land **row-major in RAM** (row stride 2W
  words). Y2 and Y4 are the right halves; Y3 starts at row 8.
- Check, 15-bit: Y2 row r, word w → stream index 32 + 4r + w → address 8r + 4 + w. ✓

**FPGA choice:** emulate it as above (status-driven offset in ps1_dma ch1), or
do what [MR] does: buffer the whole colour macroblock (256 entries × 24 bits, the
768 B the die has) and emit it row-major, with DMA1 linear. The second way is
simpler and identical for DMA1. Only CPU polling of 1F801820h would then see 16x16
order instead of 8x8. 

**FIFOs** ([SPX] diagram, [MF]): data-in is 32 words, data-out is 32 words.
- Games run DMA0 and DMA1 in SyncMode 1 (blocks) with BS = 20h words:
  DMA0 CHCR = 01000201h, DMA1 CHCR = 01000200h. The RLE data is padded with FE00h
  to a whole 32-word block.
- DREQ0 asks for exactly one 32-word block when the in-FIFO is empty and the
  command wants more. DREQ1 offers a block when 32 words are ready.
- When the out-FIFO is full, the decoder stalls. While output is backed up it does
  not consume input.
- DMA0 and DMA1 each move 1 word per clock [SPX], plus however long the decode takes.
- A typical frame: CD → RAM (DMA3), the CPU decodes the Huffman bitstream into RLE
  halfwords, RAM → MDEC (DMA0), MDEC → RAM (DMA1), and RAM → VRAM (DMA2). Frames
  are made of vertical columns of macroblocks (for example a 16x240 strip per
  GPU copy).

---------------------------------------------------------------------------
## 7. Timing and quirks games depend on

- **Speed:** the spec figure is 9000 macroblocks/s, enough for 300 macroblocks
  per 320x240 frame at 30 fps. That is about 3760 CPU clocks (33.8688 MHz) per
  colour macroblock.
  - [MF]: averages about 512 clocks per 8x8 block ("complex because of pipelining"),
    which is about 3072 per colour macroblock.
  - [DS]: 448 per block, 2688 per macroblock (it also charges ×6 for mono).
  - [DECAP]: 1 multiply-accumulate per clock per pass: 64 values × 8 = 512 clocks per
    block per pass, with the two passes overlapped. That matches [MF]'s 512.
  - A pipelined FPGA can be much faster, but **do not be faster than the
    hardware**. [MR] had to slow 15-bit mode by about 1085 CPU clocks per
    macroblock to fix Parasite Eve 2's in-game FMV stutter. Pace the output at
    about 512 CPU clocks per block (a parameter).
- **Do not flush the out-FIFO on a new MDEC(1).** [DS] changed this to fix
  corrupted images in Bealphareth. [MF] does flush.
- Invalid commands must not eat the FIFO (Formula 1 Rev1, [MR]). Soft reset must
  work from a CPU write (Slam Dragon, CTR previews, [MR]).
- **IDCT and colour stages need double buffering.** If the next block's IDCT
  overwrites Y or chroma while the colour stage is still reading it, Star Wars:
  The Phantom Menace shows glitches ([MR]).
- GameShark 4.0's intro uses DMA0 in an unusual way. FF7's intro and SimCity 2000's
  start-up are good test cases ([MF] header).
- [MF] notes that when a command's count runs out with the FIFO not empty, real
  hardware seems to read too far and pull garbage. Mid-block ends are undefined,
  so do not rely on them.
- Status bit 15-0 reads N−1 right after MDEC(1) is accepted, and FFFFh once all N
  words have been consumed.
- A DMA0 request is only asserted while a command expects more data, so a DMA0
  that overruns the count stalls instead of corrupting the next command. This is
  [MF]'s gating; the hardware detail is unverified.
- Test ROMs: krom's MDEC tests (PSX MiSTer brought them up first). The
  ps1-tests/DuckStation pair is the practical golden reference. Dump DMA1 output
  and compare word by word.

---------------------------------------------------------------------------
## 8. Worked examples (computed from the [MF] model in Python)

**DC only, qt[0] = 2.** The output pixel is the same for all 64:

| DC | c | pixel |
|---|---|---|
| 1 | 24 | 0 |
| 3 | 88 | 1 |
| 10 | 312 | 2 |
| 100 | 3192 | 25 |
| −100 | −3192 | −25 |
| 200 | 6392 | 50 |
| 511 | 16344 | 127 |
| −512 | −16376 | −128 |

For DC = 3: pass 1 gives (88·2896 + 4000h) >> 15 = 8, and pass 2 gives
(8·2896 + 4000h) >> 15 = 1.

**DC plus one AC.** Input halfwords 2828h (q_scale 10, DC = 40) and 0005h (run 0,
level 5, k = 1, at position (0,1)), with qt[1] = 16 (so q = 160). Then:
- c00 = 16·80 − 8 = 1272
- c01 = 16·floor(800/8) − 8 = 1592
- Pass 1: t[y][0] = 112 and t[y][1] = 141 for every y.
- Pass 2 row: 27 25 20 13 6 0 −5 −7. All 8 rows are identical.
  x=0 check: 112·2896 + 141·4017 + 4000h = 907133, and >> 15 gives 27.

**YCbCr → RGB.** Y = 50, Cb = −20, Cr = 30:
- R = 50 + ((10770 + 128) >> 8) = 50 + 42 = 92
- G = 50 + ((1760 + (−5496) + 128) >> 8) = 50 − 15 = 35
- B = 50 + ((−9080 + 128) >> 8) = 50 − 35 = 15
- Unsigned bytes: DC A3 8F.
- 15-bit: (28, 20, 18) → 4A9Ch, or CA9Ch with bit 25 set. Signed 15-bit: 088Ch.
- Y = 0, Cb = Cr = 0 → 80 80 80, 15-bit 4210h (signed 0000h).
  Y = 127, Cb = 127, Cr = 0 → R 127, G 83, B −128 (wrapped) → 15-bit 035Fh.

---------------------------------------------------------------------------
## Sources
- psx-spx (consoledev): https://psx-spx.consoledev.net/ps1/cpu/mdec/macroblockdecodermdec/
- nocash psx-spx: https://problemkaputt.de/psxspx-mdec-i-o-ports.htm, `-mdec-commands.htm`,
  `-mdec-decompression.htm`, `-mdec-data-format.htm`; DMA timing: https://problemkaputt.de/psxspx-dma-channels.htm
- Decap and hardware-test thread (psxdev.ru; nocash, Akari, org, AmiDog, LostTemplar):
  https://github.com/emu-russia/psxcpu/blob/main/mdec_topic_psxdevru.md
- Mednafen/Beetle PSX (GPL, behaviour only): https://github.com/libretro/beetle-psx-libretro/blob/master/mednafen/psx/mdec.c (+ `dma.c` for the DMA1 offset)
- DuckStation (CC-BY-NC-ND, behaviour only): https://github.com/stenzek/duckstation/blob/master/src/core/mdec.cpp and its commit log
- PSX_MiSTer (GPL, behaviour only): https://github.com/MiSTer-devel/PSX_MiSTer/blob/main/rtl/mdec.vhd and its commit log (game fixes)
- jPSXdec (its source states the IDCT is not exact): https://github.com/m35/jpsxdec (`PsxMdecIDCT_int.java`)
- Throughput figure: https://wiki.multimedia.cx/index.php/PlayStation_Motion_Decoder
