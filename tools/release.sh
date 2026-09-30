#!/usr/bin/env bash
# Package a release: the core images, the ESP32 firmware and the source, with
# checksums, in dist/fpga-console-<VERSION>/.
#
#   ./tools/release.sh
#
# It packages what is in cores/, so build every image first (tools/core.sh
# shell|nes|sms|md|ps1, EFFORT=1 for ps1) and try each one on the board. It
# refuses to run with uncommitted changes, because the source archive is the
# COMMIT and the images must have been built from exactly that; and it refuses
# an image older than the newest RTL, the same guard tools/ps1flash.py has --
# an interrupted build leaves the previous image in place, and shipping that
# looks exactly like shipping the new one.
set -e
cd "$(dirname "$0")/.."

VER=$(tr -d '\r\n' < VERSION)
NAME=fpga-console-$VER
OUT=dist/$NAME
FQBN="esp32:esp32:esp32s3:PSRAM=opi,FlashSize=8M"

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "uncommitted changes: commit them first (the source archive is the commit)" >&2
  exit 1
fi

newest=$(ls -t rtl/*.v boards/qmtech_a100t/*.xdc | head -1)
for c in shell nes sms md ps1; do
  img=cores/$c.bin
  [ -f "$img" ] || { echo "$img is missing: build it with tools/core.sh $c" >&2; exit 1; }
  [ "$img" -nt "$newest" ] || { echo "$img is older than $newest: rebuild it" >&2; exit 1; }
done

rm -rf "$OUT"
mkdir -p "$OUT/cores" "$OUT/esp32"
for c in shell nes sms md ps1; do cp "cores/$c.bin" "$OUT/cores/"; done

# the ESP32 front door, as the images arduino-cli would flash
if [ -x tools/arduino/arduino-cli.exe ] || command -v arduino-cli >/dev/null; then
  CLI=tools/arduino/arduino-cli.exe; [ -x "$CLI" ] || CLI=arduino-cli
  "$CLI" compile --fqbn "$FQBN" --output-dir "$OUT/esp32/build" esp32/console >/dev/null
  cp "$OUT/esp32/build/console.ino.merged.bin" "$OUT/esp32/console-esp32s3.bin" 2>/dev/null || true
  rm -rf "$OUT/esp32/build"
else
  echo "(no arduino-cli: the ESP32 firmware is not in this release)"
fi

git archive --format=zip --prefix="$NAME/" -o "$OUT/$NAME-source.zip" HEAD
git rev-parse HEAD > "$OUT/COMMIT"
cp CHANGELOG.md "$OUT/"

( cd "$OUT" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS )
echo "$OUT:"
ls -la "$OUT" "$OUT/cores" "$OUT/esp32"
