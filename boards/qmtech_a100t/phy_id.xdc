#==============================================================================
# phy_id - MDIO-only constraints, header U4. Two signal wires plus power.
#
# The canonical LAN8720 pin map lives in lan8720.xdc; this file repeats only the
# two pins phy_id uses. The duplication is deliberate: tools/build.tcl takes a
# single -xdc and calls read_xdc before synth_design, so constraints must be
# plain and every constrained port must exist in the top level.
#
#   U4 pin 59  U2(ball)  eth_mdc   -> module MDC
#   U4 pin 60  U1(ball)  eth_mdio  -> module MDIO
#
# These are the third pin-pair in from the 63/64 end: skip 63/64 (VIN) and
# 61/62 (GND), and the next pair is 59/60.
#
#   power   3V3 from U2 pins 1-6 (pin 3 confirmed working). NOT U4 pins 1-6,
#           which are VCCO_34_35, the bank voltage feed.
#           GND from U4 pin 61. NOT 63/64 - those are VIN.
#
# Beware the ball names: U4 pin 59 is ball "U2" and pin 60 is ball "U1". Those
# are FPGA package balls that happen to be spelled like the header designators.
#==============================================================================

set_property -dict {PACKAGE_PIN U22 IOSTANDARD LVCMOS33} [get_ports sys_clk]
set_property -dict {PACKAGE_PIN T23 IOSTANDARD LVCMOS33} [get_ports led0]
set_property -dict {PACKAGE_PIN R23 IOSTANDARD LVCMOS33} [get_ports led1]

create_clock -name sys_clk -period 20.000 [get_ports sys_clk]

# MDIO is released by the master for the turnaround and driven by the PHY. The
# module carries its own pull-up; a weak one here keeps the line defined when the
# dongle is unplugged.
set_property -dict {PACKAGE_PIN U2 IOSTANDARD LVCMOS33} [get_ports eth_mdc]
set_property -dict {PACKAGE_PIN U1 IOSTANDARD LVCMOS33 PULLUP true} [get_ports eth_mdio]

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLDOWN [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
