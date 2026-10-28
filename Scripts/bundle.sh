#!/bin/bash
# Assembles LemmaryLocalAI.app from built products. Used by dev.sh and
# release.sh; not meant to be run on its own.
#
#   bundle.sh <bin-dir> <app-path>
#
# Layout:
#   Contents/MacOS/LemmaryLocalAI   the menu bar app
#   Contents/MacOS/ocr-worker       one process per OCR conversion
#   Contents/MacOS/llama-server     upstream llama.cpp, unmodified but for an rpath
#   Contents/Frameworks/*.dylib     what llama-server links, and nothing else
#
# SIGN_IDENTITY selects the signature: "-" (default) is ad-hoc, for this Mac
# only; a "Developer ID Application: …" identity signs for distribution, with
# the hardened runtime that notarization requires.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$1"
APP="$2"
IDENTITY="${SIGN_IDENTITY:--}"
LLAMA="$(Scripts/fetch-llama.sh)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/LemmaryLocalAI" "$BIN/ocr-worker" "$APP/Contents/MacOS/"
cp "$LLAMA/llama-server" "$APP/Contents/MacOS/"
cp "$LLAMA/LICENSE" "$APP/Contents/Resources/llama.cpp-LICENSE"

# Copy the @rpath closure of llama-server: it links ten dylibs of the
# forty-odd in the release, and they link each other.
pending=("$LLAMA/llama-server")
while [ ${#pending[@]} -gt 0 ]; do
  current="${pending[0]}"
  pending=("${pending[@]:1}")
  for dep in $(otool -L "$current" | awk '/@rpath\//{print $1}'); do
    name="${dep#@rpath/}"
    if [ ! -f "$APP/Contents/Frameworks/$name" ]; then
      cp -L "$LLAMA/$name" "$APP/Contents/Frameworks/$name"
      pending+=("$LLAMA/$name")
    fi
  done
done
# The release looks for its dylibs beside the binary (@loader_path); here they
# are in Frameworks.
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/llama-server" 2>/dev/null

sign() {
  local out
  if [ "$IDENTITY" = "-" ]; then
    out="$(codesign --force --sign - "$@" 2>&1)" || { echo "$out" >&2; exit 1; }
  else
    out="$(codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@" 2>&1)" || { echo "$out" >&2; exit 1; }
  fi
}
# Inside out: nested code first, the bundle last.
for lib in "$APP"/Contents/Frameworks/*.dylib; do sign "$lib"; done
sign "$APP/Contents/MacOS/llama-server"
sign "$APP/Contents/MacOS/ocr-worker"
sign "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
