#!/bin/bash
# Optimized build of LemmaryLocalAI.app.
#
#   Scripts/release.sh [--install] [--notarize]
#
# --install    copies it to /Applications (quitting a running copy first)
# --notarize   needs SIGN_IDENTITY set to a Developer ID identity and
#              NOTARY_PROFILE to a `xcrun notarytool store-credentials` profile
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0
NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --notarize) NOTARIZE=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "release.sh: unknown option $arg" >&2; exit 2 ;;
  esac
done

swift build -c release --product LemmaryLocalAI
swift build -c release --product ocr-worker
APP=".build/release-app/LemmaryLocalAI.app"
mkdir -p "$(dirname "$APP")"

# Stamp the commit into CFBundleVersion so a stale /Applications copy is
# recognisable from `mdls`.
Scripts/bundle.sh "$(swift build -c release --show-bin-path)" "$APP"
if REV="$(git rev-parse --short HEAD 2>/dev/null)"; then
  [ -z "$(git status --porcelain 2>/dev/null)" ] || REV="$REV-dirty"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $REV" "$APP/Contents/Info.plist"
  # The plist is sealed by the signature, so the bundle is signed again.
  if [ "${SIGN_IDENTITY:--}" = "-" ]; then
    codesign --force --sign - "$APP" >/dev/null
  else
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP" >/dev/null
  fi
fi

if [ "$NOTARIZE" = 1 ]; then
  : "${SIGN_IDENTITY:?--notarize needs SIGN_IDENTITY (a Developer ID Application identity)}"
  : "${NOTARY_PROFILE:?--notarize needs NOTARY_PROFILE (xcrun notarytool store-credentials)}"
  ZIP="$(dirname "$APP")/LemmaryLocalAI.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
fi

if [ "$INSTALL" = 1 ]; then
  DEST="/Applications/LemmaryLocalAI.app"
  pkill -f "$DEST/Contents/MacOS/LemmaryLocalAI" 2>/dev/null || true
  sleep 1
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  echo "Installed $DEST"
fi
