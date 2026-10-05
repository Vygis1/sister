#==============================================================================
# eth_top - the full LAN8720 pinout on header U4.
#
# Canonical map and the reasoning behind it are in lan8720.xdc. Repeated here
# because tools/build.tcl takes a single -xdc and every constrained port must
# exist in the top level.
#
#   U4 pin  ball   signal
#   ------  -----  --------------------------------------------
#     47    R3     eth_refclk   nINT/REFCLK  50 MHz in, MRCC
#     53    N1     eth_txd[0]   TX0
#     54    M1     eth_txd[1]   TX1
#     55    R1     eth_crs_dv   CRS
#     56    P1     eth_tx_en    TX-EN
#     57    T2     eth_rxd[0]   RX0
#     58    R2     eth_rxd[1]   RX1
#     59    U2     eth_mdc      MDC
#     60    U1     eth_mdio     MDIO
#
#   power   3V3 from U2 pins 1-6 (pin 3 confirmed). NOT U4 pins 1-6, which are
#           VCCO_34_35. GND from U4 pin 61. NOT 63/64 - those are VIN.
#==============================================================================

set_property -dict {PACKAGE_PIN U22 IOSTANDARD LVCMOS33} [get_ports sys_clk]
set_property -dict {PACKAGE_PIN T23 IOSTANDARD LVCMOS33} [get_ports led0]
set_property -dict {PACKAGE_PIN R23 IOSTANDARD LVCMOS33} [get_ports led1]

# The PHY sources REF_CLK, so this is an input and the FPGA must never drive it.
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

# The board oscillator and the PHY's REF_CLK are both 50 MHz and genuinely
# unrelated -- different crystals, no phase relationship ever.
#
# -include_generated_clocks is not decoration. The memory controller derives
# ui_clk from its own MMCM, which hangs off sys_clk, so naming sys_clk alone
# leaves ui_clk in no group at all and the tools time it against eth_refclk as
# though the two were related. Every crossing register in ddr3_mem.v then has to
# meet a requirement that does not exist: -6.9 ns of setup slack, entirely
# fictional, on a design that is actually fine.
#
# Making them false paths is safe here because the crossing is a toggle
# handshake: ddr3_mem.v holds the address, the write data and the direction
# steady from the request until the acknowledgement comes back, and the toggle
# itself spends three flip-flops in a synchroniser before anything reads them.
# The payload has tens of nanoseconds to settle, not one clock edge.
set_clock_groups -asynchronous     -group [get_clocks -include_generated_clocks sys_clk]     -group [get_clocks -include_generated_clocks eth_refclk]

# The console's own clock (cclk, eth_top.v's MMCM through bufg_con) comes from the
# same oscillator as the memory controller's and the HDMI clocks, so the tools would
# take them as related. Every crossing between them is a handshake or a synchroniser
# (ddr3_mem.v's toggles, the picture's line buffer, the audio toggle), never a path
# of one clock edge: unrelated, as they were when the console ran on REF_CLK.
set cclk [get_clocks -of_objects [get_pins bufg_con/O]]
set_clock_groups -asynchronous -group $cclk -group [get_clocks -include_generated_clocks sys_clk -filter "NAME != [get_property NAME $cclk]"]

# RMII input setup/hold against REF_CLK. The PHY drives these from the same
# clock edge we sample on, so give the tools the real window rather than letting
# them assume the whole period is available.
set_input_delay -clock eth_refclk -max 14.000 [get_ports {eth_rxd[*] eth_crs_dv}]
set_input_delay -clock eth_refclk -min 2.000  [get_ports {eth_rxd[*] eth_crs_dv}]
set_output_delay -clock eth_refclk -max 6.000 [get_ports {eth_txd[*] eth_tx_en}]
set_output_delay -clock eth_refclk -min 0.000 [get_ports {eth_txd[*] eth_tx_en}]

# MDIO is asynchronous to everything and runs at 1.5 MHz; do not time it.
set_false_path -to   [get_ports eth_mdc]
set_false_path -from [get_ports eth_mdio]
set_false_path -to   [get_ports eth_mdio]

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLDOWN [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 1 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property CONFIG_MODE SPIx1 [current_design]

# --- the ESP32's SPI wires on header U2 (pins 7-10), as in shell_top.xdc ---------------
set_property -dict {PACKAGE_PIN D26 IOSTANDARD LVCMOS33} [get_ports esp_sclk]
set_property -dict {PACKAGE_PIN E26 IOSTANDARD LVCMOS33} [get_ports esp_mosi]
set_property -dict {PACKAGE_PIN D25 IOSTANDARD LVCMOS33} [get_ports esp_miso]
set_property -dict {PACKAGE_PIN E25 IOSTANDARD LVCMOS33 PULLUP true} [get_ports esp_cs_n]
# --- HDMI: a bare connector breakout on header U4 pins 7-26, turned so the socket faces
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
