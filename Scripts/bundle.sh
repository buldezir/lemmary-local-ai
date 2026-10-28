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
#   Contents/Frameworks/Sparkle.framework   the app's updater
#
# IDENTITY selects the signature: unset is ad hoc, for this Mac only; a
# "Developer ID Application" identity signs for distribution, with the hardened
# runtime and secure timestamp that notarization requires. VERSION, BUILD and
# BUNDLE_ID override Resources/Info.plist's; without BUILD, the build number is
# the commit, so a stale copy in /Applications is recognisable.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$1"
APP="$2"
IDENTITY="${IDENTITY:--}"
LLAMA="$(Scripts/fetch-llama.sh)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/LemmaryLocalAI.icns "$APP/Contents/Resources/LemmaryLocalAI.icns"
cp "$BIN/LemmaryLocalAI" "$BIN/ocr-worker" "$APP/Contents/MacOS/"
cp "$LLAMA/llama-server" "$APP/Contents/MacOS/"
cp "$LLAMA/LICENSE" "$APP/Contents/Resources/llama.cpp-LICENSE"
# The updater: swift build leaves it next to the binary, an app keeps it in Frameworks.
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/LemmaryLocalAI" 2>/dev/null

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

PLIST="$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"; fi
if [ -n "${BUNDLE_ID:-}" ]; then plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$PLIST"; fi
if [ -n "${BUILD:-}" ]; then
  plutil -replace CFBundleVersion -string "$BUILD" "$PLIST"
elif REV="$(git rev-parse --short HEAD 2>/dev/null)"; then
  [ -z "$(git status --porcelain 2>/dev/null)" ] || REV="$REV-dirty"
  plutil -replace CFBundleVersion -string "$REV" "$PLIST"
fi

sign() {
  local out
  if [ "$IDENTITY" = "-" ]; then
    out="$(codesign --force --sign - "$@" 2>&1)" || { echo "$out" >&2; exit 1; }
  else
    out="$(codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@" 2>&1)" || { echo "$out" >&2; exit 1; }
  fi
}
# Inside out: nested code first, the bundle last. Sparkle's helpers are signed
# by sign-sparkle.sh for a Developer ID build, and keep Sparkle's own signatures
# otherwise. An ad hoc signature goes without the hardened runtime: its library
# validation would stop an ad hoc app from loading Sparkle.framework, which is
# signed by Sparkle's team.
for lib in "$APP"/Contents/Frameworks/*.dylib; do sign "$lib"; done
sign "$APP/Contents/MacOS/llama-server"
sign "$APP/Contents/MacOS/ocr-worker"
case "$IDENTITY" in
"Developer ID"*) Scripts/sign-sparkle.sh "$APP" "$IDENTITY" ;;
esac
sign "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
