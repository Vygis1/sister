#==============================================================================
# ps2net - REAL PINOUT for the QMTECH XC7A100T core board
#
#   Board  : QMTECH Artix-7 XC7A100T core board
#   FPGA   : XC7A100T-1FGG676C          Part: xc7a100tfgg676-1
#   Headers: U2 and U4, 64-pin 2.54 mm. Signals occupy pins 7-60 on both;
#            1-6 and 61-64 are power and ground.
#
# Recovered from the vendor schematic
# QMTECH_XC7A75T_100T_200T-CORE-BOARD-V01-20210109.pdf, where every header net is
# named BANK<n>_<ball> or IO_<ball> - the ball is carried by the net name.
#
# CROSS-VALIDATED. Two independent extractions agree: the header figures give 108
# signals on pins 7-60 with no duplicate pin and no duplicate ball, and the set of
# balls is identical to the 108 counted from the user manual. Every ball was then
# confirmed against the device itself as bonded and general-purpose.
#
# Signals are laid out in ASCENDING HEADER PIN ORDER within each group, so a bus
# runs along consecutive pins and the ribbon does not have to cross over.
#
#==============================================================================
# BEFORE YOU WIRE ANYTHING
#
# BANKS 34/35 MUST STAY AT 3.3 V. They are 3.3 V by default through the 0 ohm
# links R14/R15 - leave those populated. Removing them lets VCCO_34_35 be injected
# from U4 pins 1-2 instead, which this design does not want.
#
# ACS_LED HAS A PIN BUT MUST NOT BE WIRED. CN504 pin 90 sits near +5 V through
# 180 ohm and Artix-7 is not 5 V tolerant. It is assigned only because the port
# exists in the RTL. Leave the header pin open.
#
# The TFlash/SD and factory-test groups are inherited scaffolding. They need no
# wire either; they are assigned so the tool has a complete constraint set.
#==============================================================================

set_property IOSTANDARD LVCMOS33 [get_ports *]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

#-----------------------------------------------------------------------------
# CLOCKS. All three clock flip-flops in the netlist, so all three sit on
# clock-capable MASTER balls. A clock on an N-side ball is DRC error PLIO-9.
#   header U2        pin  ball
#-----------------------------------------------------------------------------
set_property PACKAGE_PIN G20  [get_ports {CLKin}]               ;# U2 pin 20
set_property PACKAGE_PIN H21  [get_ports {bcWr}]                ;# U2 pin 22
set_property PACKAGE_PIN K21  [get_ports {bcRd}]                ;# U2 pin 24

#-----------------------------------------------------------------------------
# CN504 console bus - address
#   header U2        pin  ball
#-----------------------------------------------------------------------------
set_property PACKAGE_PIN D26  [get_ports {cAP[0]}]              ;# U2 pin  7
set_property PACKAGE_PIN E26  [get_ports {cAP[1]}]              ;# U2 pin  8
set_property PACKAGE_PIN D25  [get_ports {cAP[2]}]              ;# U2 pin  9
set_property PACKAGE_PIN E25  [get_ports {cAP[3]}]              ;# U2 pin 10
set_property PACKAGE_PIN G26  [get_ports {cAP[4]}]              ;# U2 pin 11
set_property PACKAGE_PIN H26  [get_ports {cAP[5]}]              ;# U2 pin 12
set_property PACKAGE_PIN E23  [get_ports {cAP[6]}]              ;# U2 pin 13
set_property PACKAGE_PIN F23  [get_ports {cAP[7]}]              ;# U2 pin 14
set_property PACKAGE_PIN F22  [get_ports {cAP[8]}]              ;# U2 pin 15
set_property PACKAGE_PIN G22  [get_ports {cAP[9]}]              ;# U2 pin 16
set_property PACKAGE_PIN J26  [get_ports {cAP[10]}]             ;# U2 pin 17
set_property PACKAGE_PIN J25  [get_ports {cAP[11]}]             ;# U2 pin 18
set_property PACKAGE_PIN G21  [get_ports {cAP[12]}]             ;# U2 pin 19
set_property PACKAGE_PIN H22  [get_ports {cAP[13]}]             ;# U2 pin 21
set_property PACKAGE_PIN J21  [get_ports {cAP[14]}]             ;# U2 pin 23
set_property PACKAGE_PIN K26  [get_ports {cAP[15]}]             ;# U2 pin 25

#-----------------------------------------------------------------------------
# CN504 console bus - data
#   header U2        pin  ball
#-----------------------------------------------------------------------------
set_property PACKAGE_PIN K25  [get_ports {cDP[0]}]              ;# U2 pin 26
set_property PACKAGE_PIN K23  [get_ports {cDP[1]}]              ;# U2 pin 27
set_property PACKAGE_PIN K22  [get_ports {cDP[2]}]              ;# U2 pin 28
set_property PACKAGE_PIN M26  [get_ports {cDP[3]}]              ;# U2 pin 29
set_property PACKAGE_PIN N26  [get_ports {cDP[4]}]              ;# U2 pin 30
set_property PACKAGE_PIN L23  [get_ports {cDP[5]}]              ;# U2 pin 31
set_property PACKAGE_PIN L22  [get_ports {cDP[6]}]              ;# U2 pin 32
set_property PACKAGE_PIN P26  [get_ports {cDP[7]}]              ;# U2 pin 33
set_property PACKAGE_PIN R26  [get_ports {cDP[8]}]              ;# U2 pin 34
set_property PACKAGE_PIN M25  [get_ports {cDP[9]}]              ;# U2 pin 35
set_property PACKAGE_PIN M24  [get_ports {cDP[10]}]             ;# U2 pin 36
set_property PACKAGE_PIN N22  [get_ports {cDP[11]}]             ;# U2 pin 37
set_property PACKAGE_PIN N21  [get_ports {cDP[12]}]             ;# U2 pin 38
set_property PACKAGE_PIN P24  [get_ports {cDP[13]}]             ;# U2 pin 39
set_property PACKAGE_PIN P23  [get_ports {cDP[14]}]             ;# U2 pin 40
set_property PACKAGE_PIN P25  [get_ports {cDP[15]}]             ;# U2 pin 41

#-----------------------------------------------------------------------------
# CN504 console bus - control
#   header U2        pin  ball
#-----------------------------------------------------------------------------
set_property PACKAGE_PIN R25  [get_ports {bcCS}]                ;# U2 pin 42
set_property PACKAGE_PIN T25  [get_ports {bCRT}]                ;# U2 pin 43
set_property PACKAGE_PIN T24  [get_ports {bcWait}]              ;# U2 pin 44
set_property PACKAGE_PIN V21  [get_ports {bcIRQ}]               ;# U2 pin 45
set_property PACKAGE_PIN U21  [get_ports {cDQ}]                 ;# U2 pin 46
set_property PACKAGE_PIN W23  [get_ports {cDK}]                 ;# U2 pin 47
set_property PACKAGE_PIN V23  [get_ports {bCSRST}]              ;# U2 pin 48
set_property PACKAGE_PIN Y23  [get_ports {bCRST}]               ;# U2 pin 49

#-----------------------------------------------------------------------------
# CN504 extras
# ACS_LED: DO NOT WIRE. See above.
#   header U2        pin  ball
#-----------------------------------------------------------------------------
set_property PACKAGE_PIN Y22  [get_ports {HDD_ACK}]             ;# U2 pin 50
set_property PACKAGE_PIN AA25 [get_ports {ACS_LED}]             ;# U2 pin 51

#-----------------------------------------------------------------------------
# RMII reference clock
# 50 MHz - the board's own oscillator is 50 MHz.
#   header U4        pin  ball
#-----------------------------------------------------------------------------
set_property PACKAGE_PIN D4   [get_ports {rmii_clk}]            ;# U4 pin 13

#-----------------------------------------------------------------------------
# ATA drive side - data
#   header U4        pin  ball
#-----------------------------------------------------------------------------
set_property PACKAGE_PIN B5   [get_ports {iD[0]}]               ;# U4 pin  7
set_property PACKAGE_PIN A5   [get_ports {iD[1]}]               ;# U4 pin  8
set_property PACKAGE_PIN B4   [get_ports {iD[2]}]               ;# U4 pin  9
set_property PACKAGE_PIN A4   [get_ports {iD[3]}]               ;# U4 pin 10
set_property PACKAGE_PIN A3   [get_ports {iD[4]}]               ;# U4 pin 11
set_property PACKAGE_PIN A2   [get_ports {iD[5]}]               ;# U4 pin 12
set_property PACKAGE_PIN C4   [get_ports {iD[6]}]               ;# U4 pin 14
set_property PACKAGE_PIN C2   [get_ports {iD[7]}]               ;# U4 pin 15
set_property PACKAGE_PIN B2   [get_ports {iD[8]}]               ;# U4 pin 16
set_property PACKAGE_PIN E5   [get_ports {iD[9]}]               ;# U4 pin 17
set_property PACKAGE_PIN D5   [get_ports {iD[10]}]              ;# U4 pin 18
set_property PACKAGE_PIN C1   [get_ports {iD[11]}]              ;# U4 pin 19
set_property PACKAGE_PIN B1   [get_ports {iD[12]}]              ;# U4 pin 20
set_property PACKAGE_PIN E1   [get_ports {iD[13]}]              ;# U4 pin 21
set_property PACKAGE_PIN D1   [get_ports {iD[14]}]              ;# U4 pin 22
set_property PACKAGE_PIN F2   [get_ports {iD[15]}]              ;# U4 pin 23

#-----------------------------------------------------------------------------
# ATA drive side - address and control
#   header U4        pin  ball
#-----------------------------------------------------------------------------
set_property PACKAGE_PIN E2   [get_ports {iA[0]}]               ;# U4 pin 24
set_property PACKAGE_PIN G4   [get_ports {iA[1]}]               ;# U4 pin 25
set_property PACKAGE_PIN F4   [get_ports {iA[2]}]               ;# U4 pin 26
set_property PACKAGE_PIN G2   [get_ports {ibCS0}]               ;# U4 pin 27
set_property PACKAGE_PIN G1   [get_ports {ibCS1}]               ;# U4 pin 28
set_property PACKAGE_PIN J4   [get_ports {ibRST}]               ;# U4 pin 29
set_property PACKAGE_PIN H4   [get_ports {iIRQ}]                ;# U4 pin 30
set_property PACKAGE_PIN H2   [get_ports {ibWr}]                ;# U4 pin 31
set_property PACKAGE_PIN H1   [get_ports {ibRd}]                ;# U4 pin 32
set_property PACKAGE_PIN H9   [get_ports {iDQ}]                 ;# U4 pin 33
set_property PACKAGE_PIN G9   [get_ports {ibDK}]                ;# U4 pin 34
set_property PACKAGE_PIN M2   [get_ports {iRdy}]                ;# U4 pin 35
set_property PACKAGE_PIN L2   [get_ports {ibDASP}]              ;# U4 pin 36

#-----------------------------------------------------------------------------
# 74LVC245 transceiver control
#   header U4        pin  ball
#-----------------------------------------------------------------------------
set_property PACKAGE_PIN L5   [get_ports {DR245}]               ;# U4 pin 37
set_property PACKAGE_PIN K5   [get_ports {OE245}]               ;# U4 pin 38

#-----------------------------------------------------------------------------
# RMII network side
#   header U4        pin  ball
#-----------------------------------------------------------------------------
set_property PACKAGE_PIN M4   [get_ports {rmii_txd[0]}]         ;# U4 pin 39
set_property PACKAGE_PIN L4   [get_ports {rmii_txd[1]}]         ;# U4 pin 40
set_property PACKAGE_PIN N3   [get_ports {rmii_tx_en}]          ;# U4 pin 41
set_property PACKAGE_PIN N2   [get_ports {rmii_rxd[0]}]         ;# U4 pin 42
set_property PACKAGE_PIN M6   [get_ports {rmii_rxd[1]}]         ;# U4 pin 43
set_property PACKAGE_PIN M5   [get_ports {rmii_crs_dv}]         ;# U4 pin 44
set_property PACKAGE_PIN K1   [get_ports {rmii_mdc}]            ;# U4 pin 45
set_property PACKAGE_PIN J1   [get_ports {rmii_mdio}]           ;# U4 pin 46

#-----------------------------------------------------------------------------
# TFlash/SD stub - inherited
# Not needed. Leave unwired.
#   header U4        pin  ball
#-----------------------------------------------------------------------------
set_property PACKAGE_PIN R3   [get_ports {TFD0}]                ;# U4 pin 47
set_property PACKAGE_PIN P3   [get_ports {TFD1}]                ;# U4 pin 48
set_property PACKAGE_PIN T4   [get_ports {TFD2}]                ;# U4 pin 49
set_property PACKAGE_PIN T3   [get_ports {TFD3}]                ;# U4 pin 50
set_property PACKAGE_PIN P6   [get_ports {TFCLK}]               ;# U4 pin 51
set_property PACKAGE_PIN P5   [get_ports {TFSENSE}]             ;# U4 pin 52
set_property PACKAGE_PIN N1   [get_ports {TFCMD}]               ;# U4 pin 53

#-----------------------------------------------------------------------------
# Factory test pins - inherited
# No function. Leave unwired.
#   header U4        pin  ball
#-----------------------------------------------------------------------------
set_property PACKAGE_PIN M1   [get_ports {JT_Result}]           ;# U4 pin 54
set_property PACKAGE_PIN R1   [get_ports {JT_Pin1}]             ;# U4 pin 55
set_property PACKAGE_PIN P1   [get_ports {JT_bTest}]            ;# U4 pin 56

#-----------------------------------------------------------------------------
# SPARE - 13 header pins unused
#   U2 pin 52  ball Y25
#   U2 pin 53  ball AC24
#   U2 pin 54  ball AB24
#   U2 pin 55  ball Y21
#   U2 pin 56  ball W21
#   U2 pin 57  ball Y26
#   U2 pin 58  ball W25
#   U2 pin 59  ball AC26
#   U2 pin 60  ball AB26
#   U4 pin 57  ball T2
#   U4 pin 58  ball R2
#   U4 pin 59  ball U2
#   U4 pin 60  ball U1
#-----------------------------------------------------------------------------
