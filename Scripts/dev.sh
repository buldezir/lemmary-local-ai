#!/bin/bash
# Debug build of LemmaryLocalAI.app in .build/. With --run, starts it; any
# further arguments go to the app, e.g. to run beside an existing setup:
#   Scripts/dev.sh --run -EmbeddingsPort 18080 -OCRPort 15001
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product LemmaryLocalAI
swift build --product ocr-worker
APP=".build/LemmaryLocalAI.app"
Scripts/bundle.sh "$(swift build --show-bin-path)" "$APP"

if [ "${1:-}" = "--run" ]; then
  shift
  pkill -f "$PWD/$APP/Contents/MacOS/LemmaryLocalAI" 2>/dev/null || true
  exec "$APP/Contents/MacOS/LemmaryLocalAI" "$@"
fi
