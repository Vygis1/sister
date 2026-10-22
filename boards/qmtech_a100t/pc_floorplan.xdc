# The PC core only (tools/core.sh pc adds it with -xdc2): a placement region for the 486 and its L2 cache.
#
# Why: at 71.4 MHz (PC_DIV 14) the 486's limiting paths are ~78% routing -- the TLB lookup into the L2,
# the write/read stages' limit checks into the TLB, the stall chain back to decode -- and the placer
# spreads ao486 (23k LUTs) over the whole height of the part, up to the DDR3 controller at the top.
# Holding ao486 and u_l2 in the lower 110 rows (the full width) keeps those paths short: the same
# netlists measured 0.3-0.45 ns better with it than without, every time (2026-10-22, build/ao_progress.md).
# It only bounds where those cells may go; nothing else is constrained, and other logic may still use
# the region. The region is ~9,900 slices for ao486's ~6,500.
create_pblock pb_cpu
add_cells_to_pblock [get_pblocks pb_cpu] [get_cells [list u_regs/u_console/g_pc.u_pc/ao486 u_regs/u_console/g_pc.u_pc/u_l2]]
resize_pblock [get_pblocks pb_cpu] -add {SLICE_X0Y0:SLICE_X89Y109 RAMB18_X0Y0:RAMB18_X2Y43 RAMB36_X0Y0:RAMB36_X2Y21 DSP48_X0Y0:DSP48_X2Y43}
