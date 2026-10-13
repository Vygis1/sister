#!/usr/bin/env bash
# Runs blargg's cpu_instrs individual tests and instr_timing through tb_gb, all at
# once (each in its own sim directory), and prints one line per ROM.
#
#   ./tools/gb/blargg.sh            expects sim/roms/gb/01.hex .. 11.hex, instr_timing.hex
#   ./tools/gb/blargg.sh 02 09      just those
#
# Make the hex files with tools/gb/gbhex.py from https://github.com/retrio/gb-test-roms.
# The slowest (11-op a,(hl)) is about 70 M clocks, six minutes of xsim.
cd "$(dirname "$0")/../.."
ROMS="${*:-01 02 03 04 05 06 07 08 09 10 11 instr_timing}"
for r in $ROMS; do
  SIMDIR=build/sim-gb-$r ./tools/sim.sh tb_gb ROM../../sim/roms/gb/$r.hex MAXCLK120000000 > build/gb-$r.log 2>&1 &
done
wait
fail=0
for r in $ROMS; do
  if grep -q "all checks passed" build/gb-$r.log; then v=PASS; else v=FAIL; fail=1; fi
  printf '%-14s %s  %s\n' "$r" "$v" "$(grep -E '^  [0-9]+ clocks' build/gb-$r.log)"
done
exit $fail
