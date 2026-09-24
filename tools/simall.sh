#!/usr/bin/env bash
# Run every testbench that is a gate, and say which ones failed.
#
#   ./tools/simall.sh
#
# Not every file in sim/ is here. tb_nestest and tb_z80 take a long time and are
# run deliberately; tb_smsgame needs a commercial cartridge that is not in the
# tree. What is here is what has to pass before a build.
set -e
cd "$(dirname "$0")/.."

TESTS="tb_cpu6502 tb_ppu tb_apu tb_mapper tb_nes tb_z80_unit tb_z80 tb_vdp tb_sms
       tb_synth tb_rmii tb_net tb_esp_link tb_console tb_spi_flash tb_shell
       tb_m68k tb_m68krom tb_md_vdp tb_ym2612 tb_md_top tb_md_console tb_cart_cache
       tb_md_cart tb_console_sel tb_md_hw tb_mem_arb tb_ddr3_mem tb_cart_ddr3
       tb_r3000 tb_gte tb_ps1_cache tb_ps1_cache_around tb_ps1_cache_conc
       tb_ps1_blk tb_ps1_fill tb_ps1_raster tb_ps1_gpu tb_ps1_tex tb_ps1_fb
       tb_ps1_dma tb_ps1_cd tb_cd_feed tb_ps1_bios"

# tb_ps1_cdrom is NOT here: it asserts an Init response of 00, which is the
# status of a drive with a disc in it, and it never declares one. The drive
# itself is covered by tb_ps1_cd and tb_cd_feed, which both pass end to end.

# The PlayStation's benches were not here, and that is how ps1_cache came to be
# simulated for weeks with its newest input left unconnected: an X on b_first
# put the whole cache arbitration in the X state, and every PS1 bench that used
# it was deciding nothing while appearing to pass. A bench nobody runs is worth
# less than no bench, because it is quoted as evidence.

# The 68000's sweep is generated, so it is regenerated here rather than trusted
# to be current. A test ROM that is stale is a test that passes for the wrong
# reason, and the assembler that builds it checks itself first.
printf "%-16s " "m68kasm"
python tools/m68kasm.py || exit 1
printf "%-16s " "m68ktest"
python tools/m68ktest.py sim/roms/m68k/m68ktest.hex | head -1
printf "%-16s " "mdtest"
python tools/mdtest.py sim/roms/md/mdtest.hex

fail=0
for t in $TESTS; do
  printf "%-16s " "$t"
  if SIMDIR=build/simall-$t tools/sim.sh "$t" > build/simall.last 2>&1; then
    echo "pass"
  else
    echo "FAIL"
    sed -n '/FAIL/p' build/simall.last | head -5
    fail=1
  fi
done

[ $fail -eq 0 ] && echo && echo "all green"
exit $fail
