# hdmi_test_top: the board clock, an LED, and the HDMI pins exactly as in eth_top.xdc
set_property -dict {PACKAGE_PIN U22 IOSTANDARD LVCMOS33} [get_ports sys_clk]
set_property -dict {PACKAGE_PIN T23 IOSTANDARD LVCMOS33} [get_ports led0]
create_clock -name sys_clk -period 20.000 [get_ports sys_clk]
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
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLDOWN [current_design]
