> **NOT USED.** This one-plug cable on U2 57-64 was a proposal and was never built.
> The console is wired as in `docs/GUIDE.md`: jumpers on U2 7-12 and 61 (11 and 12 are
> the quad data wires, which this cable does not carry), GPIO32 to PROGRAM_B on SW1, the
> T8 powered from its own USB. The case (`enclosure/`) is laid
> out for that wiring. `cable/` (the harness drawing) belongs to this proposal too.

# The ESP32 cable — LilyGO T8 to the QMTECH board

One plug at the FPGA end, wires soldered at the T8 end. Seven wires, 100 mm each.

```
 LilyGO T8 V1.7.1                                QMTECH header U2 (male pins, up)
 (front header row, solder from below)           one 2x4 Dupont housing, pins 57-64
 ---------------------------------------         ----------------------------------
 pin  9  IO18  -- yellow --  SCLK  -->           57   Y26
 pin  8  IO23  -- green  --  MOSI  -->           58   W25
 pin  7  IO19  <- blue   --  MISO  ---           59   AC26
 pin 10  IO5   -- white  --  CS    -->           60   AB26
 pin 12  GND   -- black  --  GND   ---           61   GND
 pin 12  GND   -- black  --  GND   ---           62   GND
 pin 15  5V    <- red    --  5 V   ---           63   VIN (the board's 5 V input)
                                                 64   (empty)
```

T8 header pins are counted along the row that carries 3.3, TXD and RXD, starting
at the antenna end: 1 GND, 2 3.3, 3 IO21, 4 TXD, 5 RXD, 6 IO22, **7 IO19, 8 IO23,
9 IO18, 10 IO5**, 11 IO2, **12 GND**, 13 IO0, 14 IO4, **15 5V**.
(LilyGO's T8 V1.7.1 schematic, connector U13.)

## The plug, seen from above

Board's front edge (the U2 edge) toward you. The housing sits **flush with the
end of the header** — pins 63/64 are the last column. That end stop is the key:
the plug cannot go on past the end, and any other position leaves the last two
pins bare where you can see it.

```
                     inner row  57    59    61    63  | end of
                     edge row   58    60    62    64  | header
                               ----  ----  ----  ----
                     inner:    SCLK  MISO  GND   5V
                     edge:     MOSI  CS    GND   --
```

## Keying: clip U2 pin 64, block cavity 64

A Dupont housing has no key of its own, and two wrong ways on are dangerous:

- **turned 180 deg**, 5 V lands on pin 58, an FPGA I/O. Artix-7 is not 5 V tolerant.
- **shifted one column inward**, 5 V lands on pin 61, ground, and shorts the supply.

So: **clip U2 pin 64 off flush** with its plastic (it is VIN, duplicated on 63, and
unused), and **block cavity 64** in the housing, with a key plug or a drop of glue. The
housing then only goes on one way. Turned around, or shifted by any number of columns,
the blocked cavity lands on a pin that is still there and the plug will not seat.

## Why these pins and not U2 7-10

The ESP link used to be on U2 pins 7-10, with ground only at pins 61/62, 70 mm away.
Each SPI signal then returned through a loop the length of the board, which is
part of why 20 MHz over jumper wires failed. On pins 57-60 every signal sits next
to the two ground pins and the 5 V feed, so one plug carries everything, and the
return path is millimetres long. Pins 57-60 (bank 13, 3.3 V) are unused by every
XDC in `boards/qmtech_a100t/` (checked).

**This needs a constraint change before the cable works.** In every constraint file in
`boards/qmtech_a100t/` that places `esp_sclk` (the shell's and the system images'):

| port | was | becomes |
|---|---|---|
| `esp_sclk` | D26 (U2 7) | **Y26** (U2 57) |
| `esp_mosi` | E26 (U2 8) | **W25** (U2 58) |
| `esp_miso` | D25 (U2 9) | **AC26** (U2 59) |
| `esp_cs_n` | E25 (U2 10) | **AB26** (U2 60) — keep `PULLUP true` |

Then rebuild the shell and the cores, and write the new shell over JTAG once. The shell
already in flash still listens on pins 7-10 and cannot hear the T8 until that is done.

## Firmware pins on the T8

The T8 is a classic ESP32 (WROVER), so the S3 sketch's FSPI/HSPI names do not
carry over.

| function | ESP32 pins | bus |
|---|---|---|
| FPGA link | SCK 18, MISO 19, MOSI 23, CS 5 | VSPI (IO_MUX pins, full speed) |
| quad data 2, 3 | IO22, IO21 | VSPI's WP and HD |
| PROGRAM_B | IO32 | a fly-wire to SW1 on the QMTECH |
| microSD (built in) | CLK 14, CMD 15, D0 2, D3/CS 13 (D1 4, D2 12) | HSPI (SPI mode) |

**Correction:** the SD pins are **13/15/14/2**, read off LilyGO's V1.7.1 schematic
and pinout. The IO33/14/12/27 set in the T8 GitHub README belongs to an older
board's WAV-player example. IO12 is the flash-voltage strap on this module: never
drive it.

IO5 is a boot strap that must be high at reset. The FPGA's `esp_cs_n` is an input
with a pull-up, so it never pulls IO5 low.

## Power

The T8 runs from the console's own 5 V: U2 pin 63 (VIN, the same net as the DC
jack) into the T8's 5V pin, then through its SY8008 regulator. That keeps the radio's
transmit bursts off the FPGA's 3.3 V rail, which also sets the HDMI pins' output
swing.

- Its USB port stays usable for flashing: a Schottky diode (D13) sits between
  the USB VBUS and the rest of the board, so the 5 V from the console cannot
  back-feed the PC.
- VIN is whatever feeds the board's DC jack. This only works with a 5 V supply: anything
  higher reaches the T8's 5V pin.
- **Never connect a LiPo** to the T8's battery connector while it is wired in.
- Leave the T8's ON/OFF switch **on**.

## Ordering it made (LCSC Cable, JLCPCB's sister company)

`cable/esp-link-harness.pdf` is the drawing to upload. `cable/make_drawing.py`
regenerates it.

1. Go to <https://lcsccable.com/customize> and upload `esp-link-harness.pdf`. No
   minimum quantity; quotes come back within 24 h.
2. They may quote equivalent connector parts; that's fine for a 2.54 mm housing.
   Check that the quote still says **cavity 8 blocked**. If they can't block it,
   accept an empty cavity 8 and fill it yourself with a drop of glue.
3. Standard assembly time is 3-7 business days. To ship it in one box with a JLCPCB
   order, email both order numbers to cable@lcsc.com.

End B arrives stripped and tinned. Soldering it to the T8 is step 4 below.

## Build it yourself

1. Seven wires, 100 mm each, 26-28 AWG stranded silicone. Colours as in the table.
2. Crimp female Dupont contacts on one end; push them into a **2x4** housing in
   the positions above. Leave cavity 64 empty and block it (see Keying).
3. Twist the seven wires together loosely (about one turn per 2 cm).
4. Solder the other ends to the T8's front-row pads **from the underside**, with
   no header fitted. Both black wires go into pad 12.
5. Before it goes near the FPGA:
   - Ohm out each contact to its pad.
   - Check that the 5V pad does not beep to GND.
   - Power the QMTECH from its DC jack alone and measure **5 V between U2 pins 61
     and 63**. U2 pin 62 is listed as ground but was never buzzed on this board;
     check it now.
6. Clip U2 pin 64, then plug in. The key makes it one way only.

## Lengths, for the record

Path lengths along the case's front wire lane, from `console_case.scad`: 43-58 mm.
The other 40-50 mm is the service loop. It lets the lid, with the T8 screwed under
it, lift far enough to reach in and unplug the housing.
