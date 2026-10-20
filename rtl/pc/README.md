# rtl/pc - the PC core (a 486)

From nand2mario's 486Tang (BSD-3-Clause, LICENSE-486tang), a port of MiSTer's ao486
(ao486 by Aleksander Osman, BSD; MiSTer changes GPL/BSD, LICENSE-ao486_MiSTer). The OPL3 in
soc/sound is Greg Taylor's (LGPL-3). Taken as it is, apart from the parts that touch the board:
486Tang's SDRAM controller and SD-card driver are not here -- pc_top.v (ours) puts the memory
in DDR3 and serves the disk from the ESP32.
