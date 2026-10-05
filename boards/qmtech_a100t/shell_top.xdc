#==============================================================================
# shell_top - the golden image.
#
# Two groups of pins and one primitive.
#
# The ESP32 goes on header U2 pins 7-10, chosen because pins 1-6 of the same
# header are 3V3 and 61-62 are ground, so the whole thing is one ribbon to one
# end of one connector. Do NOT take power from U2 pins 63/64: those are VIN,
# whatever you fed the board, and they will destroy a 3.3 V module.
#
#   U2 pin  ball   signal        ESP32
#   ------  -----  ------------  -----
#      7    D26    esp_sclk      SCK
#      8    E26    esp_mosi      MOSI
#      9    D25    esp_miso      MISO
#     10    E25    esp_cs_n      CS
#      3    -      3V3           3V3    (or power the ESP32 over USB)
#     61    -      GND           GND
#
# The configuration flash is not on a header. Its pins are the FPGA's own
# dual-purpose config pins, which become ordinary I/O once configuration has
# finished -- with one exception: CCLK cannot be constrained at all and is
# reached through STARTUPE2 inside the design.
#==============================================================================

set_property -dict {PACKAGE_PIN U22 IOSTANDARD LVCMOS33} [get_ports sys_clk]
set_property -dict {PACKAGE_PIN T23 IOSTANDARD LVCMOS33} [get_ports led0]
set_property -dict {PACKAGE_PIN R23 IOSTANDARD LVCMOS33} [get_ports led1]

# --- the PC, over Ethernet ----------------------------------------------------
# The same LAN8720 pinout the console image uses, so one board wiring serves
# both and switching between them is a reconfiguration and nothing else.
set_property -dict {PACKAGE_PIN R3 IOSTANDARD LVCMOS33} [get_ports eth_refclk]
set_property -dict {PACKAGE_PIN N1 IOSTANDARD LVCMOS33} [get_ports {eth_txd[0]}]
set_property -dict {PACKAGE_PIN M1 IOSTANDARD LVCMOS33} [get_ports {eth_txd[1]}]
set_property -dict {PACKAGE_PIN R1 IOSTANDARD LVCMOS33} [get_ports eth_crs_dv]
set_property -dict {PACKAGE_PIN P1 IOSTANDARD LVCMOS33} [get_ports eth_tx_en]
set_property -dict {PACKAGE_PIN T2 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[0]}]
set_property -dict {PACKAGE_PIN R2 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[1]}]
set_property -dict {PACKAGE_PIN U2 IOSTANDARD LVCMOS33} [get_ports eth_mdc]
set_property -dict {PACKAGE_PIN U1 IOSTANDARD LVCMOS33 PULLUP true} [get_ports eth_mdio]

create_clock -name sys_clk    -period 20.000 [get_ports sys_clk]
create_clock -name eth_refclk -period 20.000 [get_ports eth_refclk]

# The only thing crossing between the two is the heartbeat LED, which shares
# nothing with anything.
# (with the clocks made from them: the HDMI picture's come from sys_clk)
set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks sys_clk] -group [get_clocks -include_generated_clocks eth_refclk]
# The shell's own clock (bufg_con) and the picture's come from one MMCM; what
# crosses between them (shell_screen's status) is synchronised, so: unrelated.
set cclk [get_clocks -of_objects [get_pins bufg_con/O]]
set_clock_groups -asynchronous -group $cclk -group [get_clocks -include_generated_clocks sys_clk -filter "NAME != [get_property NAME $cclk]"]

set_input_delay  -clock eth_refclk -max 14.000 [get_ports {eth_rxd[*] eth_crs_dv}]
set_input_delay  -clock eth_refclk -min 2.000  [get_ports {eth_rxd[*] eth_crs_dv}]
set_output_delay -clock eth_refclk -max 6.000  [get_ports {eth_txd[*] eth_tx_en}]
set_output_delay -clock eth_refclk -min 0.000  [get_ports {eth_txd[*] eth_tx_en}]

set_false_path -to   [get_ports eth_mdc]
set_false_path -from [get_ports eth_mdio]
set_false_path -to   [get_ports eth_mdio]

# --- the ESP32 ---------------------------------------------------------------
set_property -dict {PACKAGE_PIN D26 IOSTANDARD LVCMOS33} [get_ports esp_sclk]
set_property -dict {PACKAGE_PIN E26 IOSTANDARD LVCMOS33} [get_ports esp_mosi]
set_property -dict {PACKAGE_PIN D25 IOSTANDARD LVCMOS33} [get_ports esp_miso]

# Pulled up so that an ESP32 which is unplugged, unpowered or still booting
# leaves the link deselected rather than floating into it.
set_property -dict {PACKAGE_PIN E25 IOSTANDARD LVCMOS33 PULLUP true} [get_ports esp_cs_n]

# The link is asynchronous to this clock and is brought across by a three-stage
# synchroniser inside esp_link. Timing these ports against sys_clk would be
# asking the tools to constrain a relationship that does not exist.
set_false_path -from [get_ports {esp_sclk esp_mosi esp_cs_n}]
set_false_path -to   [get_ports esp_miso]

# --- the configuration flash --------------------------------------------------
#   R14  D00_MOSI   data to the flash
#   R15  D01_DIN    data from it
#   P14  D02        /W    in single-bit mode - must be high
#   N14  D03        /HOLD in single-bit mode - must be high
#   P18  FCS_B      chip select
#   H13  CCLK       via STARTUPE2, not here
#
# D02 and D03 are the trap. The board parks unused pins with a pulldown, which
# on this part means write protect asserted and the chip held, and flash writes
# that quietly do nothing. The design drives both high; these lines make sure
# they reach the right balls.
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33} [get_ports flash_mosi]
set_property -dict {PACKAGE_PIN R15 IOSTANDARD LVCMOS33} [get_ports flash_miso]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports flash_wp_n]
set_property -dict {PACKAGE_PIN N14 IOSTANDARD LVCMOS33} [get_ports flash_hold_n]
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS33} [get_ports flash_cs_n]

# The flash link runs at 6.25 MHz and its margin comes from the protocol -- the
# controller samples a bit a full half-period after driving the edge that
# produced it. Vivado cannot time it anyway: the clock leaves through STARTUPE2
# and never appears as a port, so there is no launch edge to time against.
set_false_path -from [get_ports flash_miso]
set_false_path -to   [get_ports {flash_mosi flash_cs_n flash_wp_n flash_hold_n}]

# --- configuration ------------------------------------------------------------
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLDOWN [current_design]
# Single-bit SPI, deliberately, and it matters for two separate reasons.
#
# Configuration: with SPIx4 the engine switches to four-bit reads partway through
# loading, which only works if the flash's quad-enable bit is set. On a part
# where it is not, configuration from flash fails and the board sits with DONE
# low -- which is what it did.
#
# User access: with SPIx4, D02 and D03 belong to the configuration engine. This
# design needs to DRIVE them, because in single-bit mode they are the flash's
# /W and /HOLD and a held flash answers nothing at all. They cannot be both.
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 1 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property CONFIG_MODE SPIx1 [current_design]

# If a MultiBoot image fails to load -- a half-written slot, a bitstream for the
# wrong part, a bad CRC -- the FPGA falls back to address 0 and this image comes
# up again. Without it the board would simply sit there with DONE low, which is
# indistinguishable from dead.
set_property BITSTREAM.CONFIG.CONFIGFALLBACK ENABLE [current_design]

# NEXT_CONFIG_ADDR is deliberately NOT set here, and the reason is worth keeping.
#
# Setting it makes the image a MultiBoot bitstream: the configuration engine
# reads the address out of the header and immediately warm-boots to it. Set to
# zero -- which looks harmless, and looks like it means "this is the image at
# zero" -- it warm-boots to ITSELF, reads the header again, and loops for ever.
# DONE never rises and not one error bit is set, because nothing ever went
# wrong: CRC clean, IDCODE clean, startup state machine parked at phase 0.
#
# The shell writes WBSTAR itself, at runtime, through ICAPE2. It has no use for
# the bitstream property and must not have it.

# --- HDMI: the shell's picture while a core is installed (shell_screen.v); the pins as
# in eth_top.xdc and hdmi_test.xdc
# away from the board: HDMI pin k sits on U4 pin 27-k (see HEADERS.md). The headers pair
# their balls across the two rows and the breakout puts a pair's + and - in one row, so
# no pair lands on a true P/N pair: each wire is its own LVCMOS33 output, + and - driven
# opposite by the serialisers (hdmi_tx PSEUDO), fast and strong into the display's
# 50 ohm terminations. The shields, ground, the shell, CEC, the reserved pin, DDC and
# hot-plug are held low (the display's pull-ups then cannot lift a ball to 5 V); the
# +5V pin is held at 3.3 V (the display's sign of a source).
#   HDMI 1  D2+   U4 26 F4      HDMI 3  D2-   U4 24 E2
#   HDMI 4  D1+   U4 23 F2      HDMI 6  D1-   U4 21 E1
#   HDMI 7  D0+   U4 20 B1      HDMI 9  D0-   U4 18 D5
#   HDMI 10 CLK+  U4 17 E5      HDMI 12 CLK-  U4 15 C2
#   held low: HDMI 2 G4, 5 D1, 8 C1, 11 B2, 13 C4, 14 D4, 15 A2, 16 A3, 17 A4, 19 A5, 20 B5
#   HDMI 18 +5V   U4 9  B4 (3.3 V)
set_property -dict {PACKAGE_PIN F4 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 16} [get_ports {hdmi_d_p[2]}]
set_property -dict {PACKAGE_PIN E2 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 16} [get_ports {hdmi_d_n[2]}]
set_property -dict {PACKAGE_PIN F2 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 16} [get_ports {hdmi_d_p[1]}]
set_property -dict {PACKAGE_PIN E1 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 16} [get_ports {hdmi_d_n[1]}]
set_property -dict {PACKAGE_PIN B1 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 16} [get_ports {hdmi_d_p[0]}]
set_property -dict {PACKAGE_PIN D5 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 16} [get_ports {hdmi_d_n[0]}]
set_property -dict {PACKAGE_PIN E5 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 16} [get_ports hdmi_ck_p]
set_property -dict {PACKAGE_PIN C2 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 16} [get_ports hdmi_ck_n]
set_property -dict {PACKAGE_PIN G4 IOSTANDARD LVCMOS33 DRIVE 8} [get_ports {hdmi_lo[0]}]
set_property -dict {PACKAGE_PIN D1 IOSTANDARD LVCMOS33 DRIVE 8} [get_ports {hdmi_lo[1]}]
set_property -dict {PACKAGE_PIN C1 IOSTANDARD LVCMOS33 DRIVE 8} [get_ports {hdmi_lo[2]}]
set_property -dict {PACKAGE_PIN B2 IOSTANDARD LVCMOS33 DRIVE 8} [get_ports {hdmi_lo[3]}]
set_property -dict {PACKAGE_PIN C4 IOSTANDARD LVCMOS33 DRIVE 8} [get_ports {hdmi_lo[4]}]
set_property -dict {PACKAGE_PIN D4 IOSTANDARD LVCMOS33 DRIVE 8} [get_ports {hdmi_lo[5]}]
set_property -dict {PACKAGE_PIN A2 IOSTANDARD LVCMOS33 DRIVE 8} [get_ports {hdmi_lo[6]}]
set_property -dict {PACKAGE_PIN A3 IOSTANDARD LVCMOS33 DRIVE 8} [get_ports {hdmi_lo[7]}]
set_property -dict {PACKAGE_PIN A4 IOSTANDARD LVCMOS33 DRIVE 8} [get_ports {hdmi_lo[8]}]
set_property -dict {PACKAGE_PIN A5 IOSTANDARD LVCMOS33 DRIVE 8} [get_ports {hdmi_lo[9]}]
set_property -dict {PACKAGE_PIN B5 IOSTANDARD LVCMOS33 DRIVE 8} [get_ports {hdmi_lo[10]}]
set_property -dict {PACKAGE_PIN B4 IOSTANDARD LVCMOS33 DRIVE 12} [get_ports hdmi_5v]
set_false_path -to [get_ports {hdmi_lo[*] hdmi_5v}]
