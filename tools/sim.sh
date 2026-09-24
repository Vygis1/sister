#!/usr/bin/env bash
# Run a testbench under Vivado's xsim. There is no iverilog on this machine, and
# xsim ships with the toolchain we already depend on.
#
#   ./tools/sim.sh tb_rmii            - compile rtl/ + sim/, run sim/tb_rmii.v
#
# Exits non-zero if the testbench prints FAIL, so it is usable as a gate.
set -e
cd "$(dirname "$0")/.."
# Absolute, so the working directory below can be nested however deep it likes
# without the ../.. count having to be kept in step with it.
ROOT="$PWD"

TB="${1:?usage: tools/sim.sh <testbench-name>}"

if [ -z "$VIVADO_BIN" ]; then
  for c in /c/AMDDesignTools/*/Vivado/bin /c/Xilinx/Vivado/*/bin; do
    [ -d "$c" ] && VIVADO_BIN="$c" && break
  done
fi
XVLOG="$VIVADO_BIN/xvlog.bat"; XELAB="$VIVADO_BIN/xelab.bat"; XSIM="$VIVADO_BIN/xsim.bat"
[ -f "$XVLOG" ] || { echo "xvlog not found; set VIVADO_BIN" >&2; exit 1; }

# One directory per testbench. They used to share build/sim, which is fine until
# two runs overlap -- a manual sim.sh alongside simall.sh -- and then one clobbers
# the other's compiled snapshot and reports a failure that is not real.
#
# The name has a dash in it rather than a slash on purpose: testbenches load
# their ROMs with relative paths like "../../sim/roms/...", so the working
# directory has to stay exactly two levels below the root.
# Still overridable, so a long run (ZEXDOC takes hours) can sit somewhere else.
OUT="${SIMDIR:-build/sim-$TB}"
mkdir -p "$OUT"
cd "$OUT"

# rtl, then any shared simulation models, then the testbench itself. The
# models are separate files because more than one bench wants them -- a flash
# chip is needed by both the flash controller and the shell that drives it.
MODELS=$(ls "$ROOT"/sim/*_model.v 2>/dev/null || true)

# glbl.v carries the global set/reset that Xilinx primitive models expect to
# find. Without it anything instantiating ICAPE2 or STARTUPE2 fails to
# elaborate; with it, and unused, it does nothing at all. Cheaper to always
# have than to work out which testbenches need it.
GLBL="$VIVADO_BIN/../../data/verilog/src/glbl.v"
[ -f "$GLBL" ] || GLBL=""

"$XVLOG" --nolog "$ROOT"/rtl/*.v $MODELS "$ROOT"/sim/"$TB".v $GLBL > xvlog.log 2>&1 || { cat xvlog.log; exit 1; }
# unisims for the designs that instantiate Xilinx primitives directly. The
# shell has to: ICAPE2 is the only way to restart configuration and STARTUPE2
# the only way to reach the flash clock, and neither can be written in Verilog.
TOPS="$TB"
[ -n "$GLBL" ] && TOPS="$TB glbl"
"$XELAB" --nolog -debug off -L unisims_ver -L secureip          -s "$TB"_snap $TOPS > xelab.log 2>&1 || { cat xelab.log; exit 1; }
# anything after the bench name is a plusarg for it: ./tools/sim.sh tb_x FOO=3 -> $value$plusargs("FOO=%d")
PLUS=""; for a in "${@:2}"; do PLUS="$PLUS --testplusarg $a"; done
"$XSIM" --nolog "$TB"_snap -R $PLUS > run.log 2>&1 || { cat run.log; exit 1; }

grep -vE '^(#|\s*$)' run.log | grep -viE 'xsim|vivado simulator|copyright|^Time resolution' || true

# A testbench that hangs prints its timeout and stops. That is a failure, but
# it contains no "FAIL", and the check below only asks for a result line -- so a
# hung run reported itself as passing. It did, once, for a cache that deadlocked.
# A hung or stuck run is a failure even though it prints no "FAIL": the check
# below only asks for a result line, so both reported themselves as passing.
if grep -qE "FAIL|TIMEOUT|TIMED OUT|: STUCK|: PARTIAL" run.log; then
  echo; echo "*** $TB FAILED ***"; grep -E "FAIL|TIMEOUT|: STUCK|: PARTIAL" run.log | head -3; exit 1
fi
if ! grep -q "all checks passed" run.log && ! grep -qE "^tb_[a-z0-9_]+:" run.log; then
  echo; echo "*** $TB produced no result - it probably did not compile ***"; exit 1
fi
echo; echo "=== $TB passed ==="
