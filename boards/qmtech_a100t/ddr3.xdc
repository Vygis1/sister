# DDR3 on the QMTECH XC7A75T/100T/200T core board (V01)
#
# --- NOT read by the build ------------------------------------------------------
#
# This is the record of the pinout and the reasoning behind it. The build gets
# these pins from the memory controller instead, which carries them in its own
# .prj -- generated from THIS file, so there is still one source of truth.
#
# Passing both is what it looks like when there are two: every DDR3 pin ends up
# constrained twice, and where the two disagree the controller's own byte-lane
# clocking will not route. It cost a build to find out.
#
# 256 MB Micron MT41K128M16JT-125:K, 16 bits wide, entirely in BANK 16.
#
# --- where these numbers came from --------------------------------------------
#
# Recovered from the vendor schematic
# QMTECH_XC7A75T_100T_200T-CORE-BOARD-V01-20210109.pdf, sheet 3, by pairing each
# DDR_* net label with the FPGA symbol pin directly below it. The pins are evenly
# spaced, so lining labels up by position alone is ambiguous: several offsets fit
# the geometry perfectly. The offset was settled by what DDR3 itself requires,
# which only one candidate satisfies:
#
#   * both DQS pairs land on the P and N of one L-pair, on DQS-capable pins
#   * CK+/CK- land on the P and N of one L-pair
#   * DQ0-7, DM0 and DQS0 are all in byte group T2
#   * DQ8-15, DM1 and DQS1 are all in byte group T3
#
# THERE IS NO CHIP SELECT. The sheet does not label one on the FPGA symbol
# because the board does not route one: the DRAM is a single rank and its CS# is
# tied low, permanently selected. Forty-seven signals, not forty-eight.
#
# that was exact and wrong -- it assumed 26 control signals needed 26 pins, and
# counted a signal the board does not have. E22 (IO_25_16) is simply unused.
#
# That matters more than one spare pin, because E22 sits outside every byte
# group, immediately below byte group T3 at IOB_X0Y150. A command signal there
# is phaser-clocked with no phaser to reach it, and it drags the whole T3 byte
# lane out of alignment: the controller's PHY reports byte lane A's oserdes_clk,
# iserdes_clkdiv and phaser_in as unroutable, which reads like a broken data
# lane rather than one invented pin in the lane below it.
#
# The controller must be told: <emrCSSelection> Disable in the .prj. With CS
# enabled MIG allocates the pin whether or not the board has one.
#
# CONFIRMED AGAINST THE VENDOR'S OWN CONSTRAINTS. All 47 signals below match
# ChinaQMTECH/QMTECH_XC7A75T-100T-200T_Core_Board, XC7A100T/Software_XC7A100T/
# DDR3.ucf, pin for pin -- which also settles the rail: it writes SSTL135
# throughout, so the board is the 1.35 V revision.
#
# --- SSTL15 or SSTL135? MEASURE BEFORE BUILDING ---------------------------------
#
# The two vendor documents disagree, and it is not a typo in one of them -- it is
# a board revision:
#
#   QMTECH_XC7A75T_100T_200T-CORE-BOARD-V01-20210109.pdf, sheet 3   ->  1V5
#   QMTECH_Artix-7_XC7A100T_Core_Board_User_Manual(Hardware)_V01,
#     figure 2-14, six times including the VREF divider and R34/R35 ->  1V35
#
# MT41K128M16 is a DDR3L part, which is specified at 1.35 V and will also run at
# 1.5 V, so both documents describe a working board -- just not the same one. The
# newer figure carries decoupling (C39, C40, C58, C59) the older sheet does not,
# which is what a revision looks like.
#
# This matters: the I/O standard has to match the rail. Drive SSTL15 into a
# 1.35 V rail and the levels are wrong in a way that shows up as calibration
# failing, or worse, as calibration passing and data being marginal.
#
# Settle it with a meter, not a document: measure any of the DDR3 decoupling caps
# against ground. 1.35 means SSTL135 / DIFF_SSTL135 below AND 1.35 V selected in
# the MIG wizard; 1.5 means leave this file as it stands. The pin assignments are
# identical either way -- only the standards change.
#
# Written as SSTL15 to match the older schematic, because that is the document
# the header map was validated against on this board. Treat that as the less
# likely of the two until measured.
#
# THE IOSTANDARD COLUMN BELOW IS NOT WHAT GETS BUILT. tools/migpins.py copies the
# pin numbers from this file into the controller's .prj and takes the standard
# from the .prj's <MemoryVoltage> instead -- currently 1.35 V, so SSTL135 and
# DIFF_SSTL135. Change the rail there, in one place, not in the 48 lines below.
# The pins are what this file is for; the standard is a property of the rail.
#
# MIG normally emits its own constraints -- these are the board facts it needs,
# to be merged with what the wizard generates.

set_property CFGBVS VCCO      [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

set_property -dict {PACKAGE_PIN E17  IOSTANDARD SSTL15     } [get_ports {ddr3_addr[0]}]   ;# DDR_A0, IO_L11P_T1_SRCC_16
set_property -dict {PACKAGE_PIN G17  IOSTANDARD SSTL15     } [get_ports {ddr3_addr[1]}]   ;# DDR_A1, IO_L2P_T0_16
set_property -dict {PACKAGE_PIN F17  IOSTANDARD SSTL15     } [get_ports {ddr3_addr[2]}]   ;# DDR_A2, IO_L2N_T0_16
set_property -dict {PACKAGE_PIN C17  IOSTANDARD SSTL15     } [get_ports {ddr3_addr[3]}]   ;# DDR_A3, IO_L7P_T1_16
set_property -dict {PACKAGE_PIN G16  IOSTANDARD SSTL15     } [get_ports {ddr3_addr[4]}]   ;# DDR_A4, IO_L6N_T0_VREF_16
set_property -dict {PACKAGE_PIN D16  IOSTANDARD SSTL15     } [get_ports {ddr3_addr[5]}]   ;# DDR_A5, IO_L8N_T1_16
set_property -dict {PACKAGE_PIN H16  IOSTANDARD SSTL15     } [get_ports {ddr3_addr[6]}]   ;# DDR_A6, IO_L6P_T0_16
set_property -dict {PACKAGE_PIN E16  IOSTANDARD SSTL15     } [get_ports {ddr3_addr[7]}]   ;# DDR_A7, IO_L8P_T1_16
set_property -dict {PACKAGE_PIN H14  IOSTANDARD SSTL15     } [get_ports {ddr3_addr[8]}]   ;# DDR_A8, IO_L1P_T0_16
set_property -dict {PACKAGE_PIN F15  IOSTANDARD SSTL15     } [get_ports {ddr3_addr[9]}]   ;# DDR_A9, IO_L4N_T0_16
set_property -dict {PACKAGE_PIN F20  IOSTANDARD SSTL15     } [get_ports {ddr3_addr[10]}]   ;# DDR_A10, IO_L5N_T0_16
set_property -dict {PACKAGE_PIN H15  IOSTANDARD SSTL15     } [get_ports {ddr3_addr[11]}]   ;# DDR_A11, IO_L1N_T0_16
set_property -dict {PACKAGE_PIN C18  IOSTANDARD SSTL15     } [get_ports {ddr3_addr[12]}]   ;# DDR_A12, IO_L12N_T1_MRCC_16
set_property -dict {PACKAGE_PIN G15  IOSTANDARD SSTL15     } [get_ports {ddr3_addr[13]}]   ;# DDR_A13, IO_L4P_T0_16
set_property -dict {PACKAGE_PIN B17  IOSTANDARD SSTL15     } [get_ports {ddr3_ba[0]}]   ;# DDR_BA0, IO_L7N_T1_16
set_property -dict {PACKAGE_PIN D18  IOSTANDARD SSTL15     } [get_ports {ddr3_ba[1]}]   ;# DDR_BA1, IO_L12P_T1_MRCC_16
set_property -dict {PACKAGE_PIN A17  IOSTANDARD SSTL15     } [get_ports {ddr3_ba[2]}]   ;# DDR_BA2, IO_L9P_T1_DQS_16
set_property -dict {PACKAGE_PIN B19  IOSTANDARD SSTL15     } [get_ports {ddr3_cas_n}]   ;# DDR_CAS, IO_L10P_T1_16
set_property -dict {PACKAGE_PIN F19  IOSTANDARD DIFF_SSTL15} [get_ports {ddr3_ck_n}]   ;# DDR_CLK-, IO_L3N_T0_DQS_16
set_property -dict {PACKAGE_PIN F18  IOSTANDARD DIFF_SSTL15} [get_ports {ddr3_ck_p}]   ;# DDR_CLK+, IO_L3P_T0_DQS_16
set_property -dict {PACKAGE_PIN E18  IOSTANDARD SSTL15     } [get_ports {ddr3_cke[0]}]   ;# DDR_CKE, IO_L11N_T1_SRCC_16
set_property -dict {PACKAGE_PIN A22  IOSTANDARD SSTL15     } [get_ports {ddr3_dm[0]}]   ;# DDR_DQM0, IO_L17N_T2_16
set_property -dict {PACKAGE_PIN C22  IOSTANDARD SSTL15     } [get_ports {ddr3_dm[1]}]   ;# DDR_DQM1, IO_L19P_T3_16
set_property -dict {PACKAGE_PIN D21  IOSTANDARD SSTL15     } [get_ports {ddr3_dq[0]}]   ;# DDR_D0, IO_L18N_T2_16
set_property -dict {PACKAGE_PIN C21  IOSTANDARD SSTL15     } [get_ports {ddr3_dq[1]}]   ;# DDR_D1, IO_L16P_T2_16
set_property -dict {PACKAGE_PIN B22  IOSTANDARD SSTL15     } [get_ports {ddr3_dq[2]}]   ;# DDR_D2, IO_L17P_T2_16
set_property -dict {PACKAGE_PIN B21  IOSTANDARD SSTL15     } [get_ports {ddr3_dq[3]}]   ;# DDR_D3, IO_L16N_T2_16
set_property -dict {PACKAGE_PIN D19  IOSTANDARD SSTL15     } [get_ports {ddr3_dq[4]}]   ;# DDR_D4, IO_L13P_T2_MRCC_16
set_property -dict {PACKAGE_PIN E20  IOSTANDARD SSTL15     } [get_ports {ddr3_dq[5]}]   ;# DDR_D5, IO_L14P_T2_SRCC_16
set_property -dict {PACKAGE_PIN C19  IOSTANDARD SSTL15     } [get_ports {ddr3_dq[6]}]   ;# DDR_D6, IO_L13N_T2_MRCC_16
set_property -dict {PACKAGE_PIN D20  IOSTANDARD SSTL15     } [get_ports {ddr3_dq[7]}]   ;# DDR_D7, IO_L14N_T2_SRCC_16
set_property -dict {PACKAGE_PIN C23  IOSTANDARD SSTL15     } [get_ports {ddr3_dq[8]}]   ;# DDR_D8, IO_L19N_T3_VREF_16
set_property -dict {PACKAGE_PIN D23  IOSTANDARD SSTL15     } [get_ports {ddr3_dq[9]}]   ;# DDR_D9, IO_L24P_T3_16
set_property -dict {PACKAGE_PIN B24  IOSTANDARD SSTL15     } [get_ports {ddr3_dq[10]}]   ;# DDR_D10, IO_L23N_T3_16
set_property -dict {PACKAGE_PIN B25  IOSTANDARD SSTL15     } [get_ports {ddr3_dq[11]}]   ;# DDR_D11, IO_L20P_T3_16
set_property -dict {PACKAGE_PIN C24  IOSTANDARD SSTL15     } [get_ports {ddr3_dq[12]}]   ;# DDR_D12, IO_L23P_T3_16
set_property -dict {PACKAGE_PIN C26  IOSTANDARD SSTL15     } [get_ports {ddr3_dq[13]}]   ;# DDR_D13, IO_L22P_T3_16
set_property -dict {PACKAGE_PIN A25  IOSTANDARD SSTL15     } [get_ports {ddr3_dq[14]}]   ;# DDR_D14, IO_L20N_T3_16
set_property -dict {PACKAGE_PIN B26  IOSTANDARD SSTL15     } [get_ports {ddr3_dq[15]}]   ;# DDR_D15, IO_L22N_T3_16
set_property -dict {PACKAGE_PIN A20  IOSTANDARD DIFF_SSTL15} [get_ports {ddr3_dqs_n[0]}]   ;# DDR_DQS0-, IO_L15N_T2_DQS_16
set_property -dict {PACKAGE_PIN A24  IOSTANDARD DIFF_SSTL15} [get_ports {ddr3_dqs_n[1]}]   ;# DDR_DQS1-, IO_L21N_T3_DQS_16
set_property -dict {PACKAGE_PIN B20  IOSTANDARD DIFF_SSTL15} [get_ports {ddr3_dqs_p[0]}]   ;# DDR_DQS0+, IO_L15P_T2_DQS_16
set_property -dict {PACKAGE_PIN A23  IOSTANDARD DIFF_SSTL15} [get_ports {ddr3_dqs_p[1]}]   ;# DDR_DQS1+, IO_L21P_T3_DQS_16
set_property -dict {PACKAGE_PIN G19  IOSTANDARD SSTL15     } [get_ports {ddr3_odt[0]}]   ;# DDR_ODT, IO_L5P_T0_16
set_property -dict {PACKAGE_PIN A19  IOSTANDARD SSTL15     } [get_ports {ddr3_ras_n}]   ;# DDR_RAS, IO_L10N_T1_16
set_property -dict {PACKAGE_PIN H17  IOSTANDARD SSTL15     } [get_ports {ddr3_reset_n}]   ;# DDR_RESETN, IO_0_16
set_property -dict {PACKAGE_PIN A18  IOSTANDARD SSTL15     } [get_ports {ddr3_we_n}]   ;# DDR_WE, IO_L9N_T1_DQS_16
