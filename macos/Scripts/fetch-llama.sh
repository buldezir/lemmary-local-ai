#!/bin/bash
# Fetches the pinned upstream llama.cpp macOS build into Vendor/. Only
# llama-server and the dylibs it loads end up in the app (see bundle.sh).
#
# To move to a newer build: change LLAMA_BUILD, set LLAMA_SHA256 to the
# tarball's `shasum -a 256`, and check embeddings still match (README).
set -euo pipefail
cd "$(dirname "$0")/.."

LLAMA_BUILD=b11936
LLAMA_SHA256=21f835a2af2aa06345f10e3d8f054c1d94a6e7932401d9752e512b6a9133e845
DEST="Vendor/llama.cpp/$LLAMA_BUILD"

if [ -x "$DEST/llama-server" ]; then
  echo "$DEST"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/llama.tgz" \
  "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_BUILD/llama-$LLAMA_BUILD-bin-macos-arm64.tar.gz"
echo "$LLAMA_SHA256  $TMP/llama.tgz" | shasum -a 256 -c - >/dev/null
mkdir -p "$TMP/x"
tar -xzf "$TMP/llama.tgz" -C "$TMP/x"
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
mv "$TMP/x/llama-$LLAMA_BUILD" "$DEST"
echo "$DEST"
