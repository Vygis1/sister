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
