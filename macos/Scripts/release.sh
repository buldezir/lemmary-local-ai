#!/bin/bash
# Optimized build of LemmaryLocalAI.app, ad hoc signed for this Mac only: a
# local build, version 0.1, which doesn't update itself. A release is built by
# .github/workflows/build.yml, which passes IDENTITY="Developer ID Application"
# and VERSION, BUILD and BUNDLE_ID (see bundle.sh), and notarizes it.
#
#   Scripts/release.sh [--install]
#
# --install    copies it to /Applications (quitting a running copy first)
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "release.sh: unknown option $arg" >&2; exit 2 ;;
  esac
done

swift build -c release --product LemmaryLocalAI
swift build -c release --product ocr-worker
APP=".build/release-app/LemmaryLocalAI.app"
mkdir -p "$(dirname "$APP")"
Scripts/bundle.sh "$(swift build -c release --show-bin-path)" "$APP"

if [ "$INSTALL" = 1 ]; then
  DEST="/Applications/LemmaryLocalAI.app"
  pkill -f "$DEST/Contents/MacOS/LemmaryLocalAI" 2>/dev/null || true
  sleep 1
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  echo "Installed $DEST"
fi
