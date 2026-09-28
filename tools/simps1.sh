#!/usr/bin/env bash
# Every PlayStation testbench that is a gate, and which ones failed.
#
#   ./tools/simps1.sh
#
# simall.sh covers the other cores; the PS1 ones are here because they are the
# set that has to pass before a PS1 bitstream is worth building.
cd "$(dirname "$0")/.."
TESTS="tb_ps1_cache tb_ps1_cache_bram tb_ps1_cache_around tb_ps1_cache_conc tb_ps1_cache_conc_bram tb_ps1_cache_equiv tb_ps1_spu tb_ps1_fill tb_ps1_gpu tb_ps1_gtece
       tb_ps1_scan tb_fbstream tb_net_stream tb_ps1_fb tb_ps1_c0 tb_ps1_c0fast tb_r3000 tb_ps1_bios tb_console tb_net"
bad=""
for tb in $TESTS; do
	printf "%-22s " "$tb"
	if out=$(./tools/sim.sh "$tb" 2>&1); then
		echo "$out" | tail -1
	else
		echo "FAILED"
		echo "$out" | grep -E "FAIL|Error|ERROR" | head -5 | sed 's/^/      /'
		bad="$bad $tb"
	fi
done
if [ -n "$bad" ]; then echo; echo "FAILED:$bad"; exit 1; fi
echo; echo "all PS1 testbenches passed"
