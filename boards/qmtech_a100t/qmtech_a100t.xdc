#==============================================================================
# QMTECH Artix-7 XC7A100T core board - base constraints
#
#   Part: xc7a100tfgg676-1
#
# Only the things that are physically on the core board itself: the 50 MHz
# oscillator and the two LEDs. Everything else lives on headers U2/U4 - see
# HEADERS.md for the full pin -> ball map, and add what you need per design.
#
# Balls are from the vendor schematic
# QMTECH_XC7A75T_100T_200T-CORE-BOARD-V01-20210109.pdf, whose net names carry the
# ball: SYS_CLK -> U22, IO_LED_T23 -> T23, IO_LED_R23 -> R23.
#==============================================================================

set_property -dict {PACKAGE_PIN U22 IOSTANDARD LVCMOS33} [get_ports sys_clk]
set_property -dict {PACKAGE_PIN T23 IOSTANDARD LVCMOS33} [get_ports led0]
set_property -dict {PACKAGE_PIN R23 IOSTANDARD LVCMOS33} [get_ports led1]

create_clock -name sys_clk -period 20.000 [get_ports sys_clk]

# Banks 34/35 are 3.3 V through R14/R15. Configuration bank follows VCCO.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# Unused I/O parked high-Z with a weak pull-down rather than driven.
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLDOWN [current_design]

# SPI flash boot: single-bit bus, 33 MHz. Single-bit because x4 needs the
# flash quad-enable bit set, and because in x4 the D02/D03 pins belong to the
# configuration engine -- a design that wants to drive them as /W and /HOLD
# cannot have them.
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 1 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property CONFIG_MODE SPIx1 [current_design]
