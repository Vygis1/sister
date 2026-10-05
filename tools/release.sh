#!/usr/bin/env bash
# Package a release: the core images, the ESP32 firmware and the source, with
# checksums, in dist/fpga-console-<VERSION>/.
#
#   ./tools/release.sh
#
# It packages what is in cores/, so build every image first (tools/core.sh
# shell|nes|sms|md|ps1|n64; EFFORT=1 for ps1, AREA=1 for n64) and try each one on the board. It
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

# Each image against the sources it was built from (cores/<core>.src, written by
# tools/core.sh): stale only if one of THOSE changed. (It was "older than the
# newest RTL file", which made every image stale whenever any core changed.)
CORES="shell nes sms md ps1 n64"
for c in $CORES; do
  img=cores/$c.bin
  [ -f "$img" ] || { echo "$img is missing: build it with tools/core.sh $c" >&2; exit 1; }
  [ -f "cores/$c.src" ] || { echo "cores/$c.src is missing: rebuild with tools/core.sh $c" >&2; exit 1; }
  python tools/srcstamp.py --check "cores/$c.src" >&2 || { echo "$img is stale: rebuild it with tools/core.sh $c" >&2; exit 1; }
done

rm -rf "$OUT"
mkdir -p "$OUT/cores" "$OUT/esp32"
for c in $CORES; do cp "cores/$c.bin" "$OUT/cores/"; done
# the shell as a bitstream too: the first programming writes it over JTAG (docs/GUIDE.md)
[ -f cores/shell.bit ] && cp cores/shell.bit "$OUT/cores/" || echo "(no cores/shell.bit: the package cannot be first-programmed over JTAG)"

# the ESP32 front door, as the images arduino-cli would flash
if [ -x tools/arduino/arduino-cli.exe ] || command -v arduino-cli >/dev/null; then
  CLI=tools/arduino/arduino-cli.exe; [ -x "$CLI" ] || CLI=arduino-cli
  "$CLI" compile --fqbn "$FQBN" --output-dir "$OUT/esp32/build" esp32/console >/dev/null
  cp "$OUT/esp32/build/console.ino.merged.bin" "$OUT/esp32/console-esp32s3.bin" 2>/dev/null || true
  rm -rf "$OUT/esp32/build"
  # the LilyGO T8 (classic ESP32, Bluetooth pads): Bluepad32's board package, one
  # image for offset 0 merged by hand (that package's build does not merge)
  T8="esp32-bluepad32:esp32:esp32:PSRAM=enabled,PartitionScheme=huge_app"
  if "$CLI" compile --fqbn "$T8" --output-dir "$OUT/esp32/t8" esp32/console >/dev/null 2>&1; then
    ESPTOOL=$(ls -d "$LOCALAPPDATA"/Arduino15/packages/esp32/tools/esptool_py/*/esptool.exe ~/.arduino15/packages/esp32/tools/esptool_py/*/esptool 2>/dev/null | head -1)
    BOOT0=$(find "$LOCALAPPDATA/Arduino15/packages/esp32-bluepad32" ~/.arduino15/packages/esp32-bluepad32 -name boot_app0.bin 2>/dev/null | head -1)
    if [ -n "$ESPTOOL" ] && [ -n "$BOOT0" ]; then
      "$ESPTOOL" --chip esp32 merge_bin -o "$OUT/esp32/console-t8.bin" --flash_mode dio --flash_size 4MB         0x1000 "$OUT/esp32/t8/console.ino.bootloader.bin" 0x8000 "$OUT/esp32/t8/console.ino.partitions.bin"         0xe000 "$BOOT0" 0x10000 "$OUT/esp32/t8/console.ino.bin" >/dev/null
    else
      echo "(no esptool or boot_app0.bin: the T8 firmware is not in this release)"
    fi
  else
    echo "(the Bluepad32 board package is not installed: the T8 firmware is not in this release)"
  fi
  rm -rf "$OUT/esp32/t8"
else
  echo "(no arduino-cli: the ESP32 firmware is not in this release)"
fi

git archive --format=zip --prefix="$NAME/" -o "$OUT/$NAME-source.zip" HEAD
git rev-parse HEAD > "$OUT/COMMIT"
cp CHANGELOG.md "$OUT/"
cp docs/GUIDE.md "$OUT/"

( cd "$OUT" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS )
echo "$OUT:"
ls -la "$OUT" "$OUT/cores" "$OUT/esp32"
