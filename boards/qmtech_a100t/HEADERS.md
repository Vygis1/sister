# QMTECH XC7A100T core board — I/O header map

Part: **xc7a100tfgg676-1** (XC7A100T-1FGG676C, slowest speed grade).

Two 64-pin 2.54 mm headers, **U2** and **U4**, each `HDR_32X2` — dual row, odd
pins in one row and even in the other, 1 and 2 side by side. On both, pins
**1–6 and 61–64 are power and ground**; the **54 signal pins are 7–60**, so 108
usable I/O total.

## Power pins — read this before connecting anything

Not all the power pins are the same rail, and the dangerous one is at the end
you are most likely to reach for. From vendor schematic figure 2-10:

| pins | U2 | U4 |
|---|---|---|
| 1–6 | **3V3** — the 3.3 V rail. Use this to power 3.3 V peripherals. | **VCCO_34_35** — bank voltage feed, see R14/R15 below |
| 61–62 | **GND** | **GND** |
| 63–64 | **VIN** — raw input from the power header, *not* 3.3 V | **VIN** — same |

**Do not power a 3.3 V module from pins 63/64.** VIN is whatever you feed the
board, and putting it on a LAN8720 or similar will destroy it. Take 3.3 V from
U2 pins 1–6 instead.

Pin 61 as ground is confirmed on hardware. Buzz out 62 before trusting it.

Ball assignments below were recovered from the vendor schematic
`QMTECH_XC7A75T_100T_200T-CORE-BOARD-V01-20210109.pdf`, where every header net is
named after the ball it lands on. Cross-validated two ways in the ps2net project:
108 signals, no duplicate pin, no duplicate ball, and every ball confirmed bonded
and general-purpose on the device.

## Before you wire anything

- **Banks 34/35 must stay at 3.3 V.** They are 3.3 V by default through the 0 ohm
  links **R14/R15** — leave those populated. Removing them lets VCCO_34_35 be fed
  externally from U4 pins 1–2 instead.
- Artix-7 is **not 5 V tolerant**. Nothing above 3.465 V on any header pin.
- Clock inputs must land on a clock-capable **MASTER** ball. A clock on an N-side
  ball is DRC error PLIO-9. Clock-capable master balls on U2:
  **G20** (pin 20), **H21** (pin 22), **K21** (pin 24) in bank 15, and
  **U21** (pin 46, MRCC), **Y22** (pin 50, SRCC), **W21** (pin 56, SRCC) in
  bank 13. On U4, **R3** (pin 47, MRCC).

  Do not trust `IS_GLOBAL_CLK` from `get_package_pins` — it reads 0 even on
  pins that are clock capable. `PIN_FUNC` is the property that tells the truth:
  look for `MRCC`/`SRCC` in the name, with `IS_MASTER` 1 for the P side.

## Pin → ball

| pin | U2 ball | U4 ball |
|----:|:--------|:--------|
| 7 | D26 | B5 |
| 8 | E26 | A5 |
| 9 | D25 | B4 |
| 10 | E25 | A4 |
| 11 | G26 | A3 |
| 12 | H26 | A2 |
| 13 | E23 | D4 |
| 14 | F23 | C4 |
| 15 | F22 | C2 |
| 16 | G22 | B2 |
| 17 | J26 | E5 |
| 18 | J25 | D5 |
| 19 | G21 | C1 |
| 20 | G20 | B1 |
| 21 | H22 | E1 |
| 22 | H21 | D1 |
| 23 | J21 | F2 |
| 24 | K21 | E2 |
| 25 | K26 | G4 |
| 26 | K25 | F4 |
| 27 | K23 | G2 |
| 28 | K22 | G1 |
| 29 | M26 | J4 |
| 30 | N26 | H4 |
| 31 | L23 | H2 |
| 32 | L22 | H1 |
| 33 | P26 | H9 |
| 34 | R26 | G9 |
| 35 | M25 | M2 |
| 36 | M24 | L2 |
| 37 | N22 | L5 |
| 38 | N21 | K5 |
| 39 | P24 | M4 |
| 40 | P23 | L4 |
| 41 | P25 | N3 |
| 42 | R25 | N2 |
| 43 | T25 | M6 |
| 44 | T24 | M5 |
| 45 | V21 | K1 |
| 46 | U21 | J1 |
| 47 | W23 | R3 |
| 48 | V23 | P3 |
| 49 | Y23 | T4 |
| 50 | Y22 | T3 |
| 51 | AA25 | P6 |
| 52 | Y25 | P5 |
| 53 | AC24 | N1 |
| 54 | AB24 | M1 |
| 55 | Y21 | R1 |
| 56 | W21 | P1 |
| 57 | Y26 | T2 |
| 58 | W25 | R2 |
| 59 | AC26 | U2 |
| 60 | AB26 | U1 |

## On-board pins (not on the headers)

| signal | ball | note |
|---|---|---|
| `SYS_CLK` | **U22** | 50 MHz onboard oscillator |
| LED | **T23** | schematic net `IO_LED_T23` |
| LED | **R23** | schematic net `IO_LED_R23` |

The two push-buttons (SW1/SW2) are **not mapped here** — read them off the
schematic before using them, don't guess.

## JTAG header J1

Six pins, 2.54 mm. Pins 2–5 are labelled in the schematic; **pins 1 and 6 are
inferred** (the 3V3 net sits directly above the header block, GND is what
remains) — buzz them out before connecting. Continuity from pin 6 to any ground
point confirms the orientation.

| pin | signal |
|---:|---|
| 1 | **3V3** — the programmer's VREF must connect here |
| 2 | TCK |
| 3 | TDO |
| 4 | TDI |
| 5 | TMS |
| 6 | GND |

**VREF is not optional** on a level-shifting programmer — it tells the cable what
voltage to drive. Left floating you get no device detection and no error message
pointing at the cause.

A 2x7 ribbon from a programmer will not mate with this. Female-to-female jumpers
pushed onto the programmer's header pins are the simplest route.
