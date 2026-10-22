#!/bin/sh
# check.sh - is pads_bluedroid.h's copy of Bluedroid's internals still right for the installed
# esp32:esp32 platform? Fetches that platform's ESP-IDF Bluetooth sources (sparse, once, into
# build/dl/esp-idf-<version>) and compiles abi_check.c against them with the platform's sdkconfig.
#   tools/bt_abi/check.sh            (from the repository root; Git Bash on Windows is fine)
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ROOT=$(cygpath -m "$ROOT" 2>/dev/null || echo "$ROOT")
PK="${ARDUINO_PACKAGES:-$(cygpath -m "$LOCALAPPDATA" 2>/dev/null || echo "$HOME/.arduino15")/Arduino15/packages}"
[ -d "$PK/esp32/tools/esp32-libs" ] || PK="$HOME/.arduino15/packages"
LIBS=$(ls -d "$PK"/esp32/tools/esp32-libs/* | tail -1)
IDFVER=$(sed -n 's/^esp-idf: \(v[0-9.]*\).*/\1/p' "$LIBS/versions.txt")
GCC=$(ls "$PK"/esp32/tools/esp-x32/*/bin/xtensa-esp32-elf-gcc* | head -1)
IDF="$ROOT/build/dl/esp-idf-$IDFVER"
echo "platform libraries: $LIBS (ESP-IDF $IDFVER)"
if [ ! -d "$IDF/components/bt/host/bluedroid" ]; then
  mkdir -p "$IDF" && cd "$IDF"
  git init -q && git remote add origin https://github.com/espressif/esp-idf.git
  git config core.sparseCheckout true
  printf 'components/bt/host/bluedroid/\ncomponents/bt/common/\n' > .git/info/sparse-checkout
  git fetch -q --depth 1 --filter=blob:none origin tag "$IDFVER" && git checkout -q "$IDFVER"
fi
TMP=$(mktemp -d)
C="$IDF/components"
{ for d in bt/host/bluedroid/common/include bt/host/bluedroid/stack/include bt/host/bluedroid/bta/include \
           bt/host/bluedroid/api/include/api bt/common/include bt/common/osi/include bt/host/bluedroid/btc/include; do
    echo "-I$C/$d"; done
  echo "-I$LIBS/qio_qspi/include"
  tr ' ' '\n' < "$LIBS/flags/includes" | grep -v '^-iwithprefixbefore$' | grep -v '^$' | sed "s|^|-I$LIBS/include/|"
} > "$TMP/inc.rsp"
"$GCC" -c "$ROOT/tools/bt_abi/abi_check.c" -o "$TMP/abi.o" -std=gnu17 @"$TMP/inc.rsp"
rm -rf "$TMP"
echo "OK: pads_bluedroid.h's Bluedroid declarations match ESP-IDF $IDFVER"
