#==============================================================================
# LAN8720 RMII Ethernet module on the QMTECH XC7A100T core board - header U4
#
# Self-contained: includes the base board constraints, because tools/build.tcl
# takes a single -xdc.
#
# Eight of the nine signals sit in the four pin-pairs immediately after the power
# block at the 63/64 end. REF_CLK cannot join them: it is a 50 MHz clock and has
# to land on a clock-capable master, and on U4 the highest one is pin 47. The
# full set of clock-capable masters on U4 is pins 13, 17, 25, 35, 41, 47 -- there
# is nothing above 47, so this is as close to the end as a clock can get.
#
#   U4 pin  ball   signal        module pin      notes
#   ------  -----  ------------  --------------  ----------------------------
#     47    R3     eth_refclk    nINT/REFCLK     50 MHz in - MRCC, clock capable
#     53    N1     eth_txd[0]    TX0
#     54    M1     eth_txd[1]    TX1
#     55    R1     eth_crs_dv    CRS             carrier sense / RX data valid
#     56    P1     eth_tx_en     TX-EN
#     57    T2     eth_rxd[0]    RX0
#     58    R2     eth_rxd[1]    RX1
#     59    U2     eth_mdc       MDC             management clock, ~1.5 MHz
#     60    U1     eth_mdio      MDIO            management data, bidirectional
#
# Counting from the 63/64 end of U4: skip pair 1 (63/64, VIN) and pair 2 (61/62,
# GND). Pairs 3 to 6 are 59/60, 57/58, 55/56, 53/54 - the eight signals above.
#
# POWER. Do not take 3.3 V from U4 pins 1-6: those are VCCO_34_35, the bank
# voltage feed, reaching the 3V3 rail only through the R14/R15 links. Drawing a
# module's 60 mA through them puts its switching noise straight onto the supply
# that sets this bank's I/O thresholds. Take 3V3 from U2 pins 1-6 instead; pin 3
# is confirmed working. Ground from U4 pin 61, which should match U2 pin 61 by
# symmetry -- buzz the two together to confirm before relying on it.
#
# Banks 34/35 must stay at 3.3 V: leave R14/R15 populated.
#
# Only the ports phy_probe has are constrained below. The rest of the map goes
# live when the full Ethernet top exists. Constraints must stay plain and
# declarative: build.tcl calls read_xdc before synth_design, so anything
# conditional evaluates against an empty design and silently does nothing.
#==============================================================================

#------------------------------------------------------------------- base board
set_property -dict {PACKAGE_PIN U22 IOSTANDARD LVCMOS33} [get_ports sys_clk]
set_property -dict {PACKAGE_PIN T23 IOSTANDARD LVCMOS33} [get_ports led0]
set_property -dict {PACKAGE_PIN R23 IOSTANDARD LVCMOS33} [get_ports led1]

create_clock -name sys_clk -period 20.000 [get_ports sys_clk]

#---------------------------------------------------------------------- LAN8720
# REF_CLK is an INPUT. The module is strapped for REF_CLK Out mode -- it drives
# 50 MHz out of this pin -- so the FPGA must never drive it. The pull-down makes
# an unwired module read as a dead clock rather than as noise.
set_property -dict {PACKAGE_PIN R3 IOSTANDARD LVCMOS33 PULLDOWN true} [get_ports eth_refclk]

create_clock -name eth_refclk -period 20.000 [get_ports eth_refclk]

# The PHY clock and the onboard oscillator are unrelated sources, and nothing in
# phy_probe crosses between them.
set_clock_groups -asynchronous -group [get_clocks sys_clk] -group [get_clocks eth_refclk]

#-------------------------------------------------------------------- bitstream
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# Unused I/O parked high-Z with a weak pull-down rather than driven, so this is
# safe to have loaded while the dongle is only half wired.
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLDOWN [current_design]

set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
