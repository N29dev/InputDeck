#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v swiftc >/dev/null || ! command -v clang >/dev/null; then
  echo "Error: Xcode Command Line Tools are required. Run: xcode-select --install" >&2
  exit 1
fi
mkdir -p build/InputDeck.app/Contents/{MacOS,Resources}
clang -O2 -Wall -Wextra -c Bridge.c -o build/Bridge.o
swiftc -O -import-objc-header Bridge.h main.swift build/Bridge.o \
  -framework AppKit -framework CoreGraphics \
  -o build/InputDeck.app/Contents/MacOS/InputDeck
cp overlay.html build/InputDeck.app/Contents/Resources/overlay.html
cp Info.plist build/InputDeck.app/Contents/Info.plist
codesign --force --sign - build/InputDeck.app >/dev/null
printf '\nBuilt: %s/build/InputDeck.app\n' "$PWD"
echo 'Launch with: open build/InputDeck.app'
