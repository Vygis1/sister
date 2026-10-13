`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_gb_50 - tb_gb at the board's clock: gb_top with CLK_HZ = 50 MHz, so the
// T-cycle enable comes from the phase accumulator, about one clock in twelve.
//
// The one-clock-per-dot bench missed a PPU bug that only shows when a dot is
// longer than a clock (its block-RAM reads were taken on every clock, not on the
// dot). This runs the same cartridges and the same checks the board will see.
// Twelve times the clocks, so give it twelve times MAXCLK.
//
//   ./tools/sim.sh tb_gb_50 ROM../../sim/roms/gb/acid2.hex FRAMES12 REF../../sim/roms/gb/acid2_ref.hex MAXCLK60000000
//////////////////////////////////////////////////////////////////////////////////

`define GB_TB_NAME tb_gb_50
`define GB_TB_CLK  50000000
`include "../../sim/tb_gb.v"
