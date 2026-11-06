#!/bin/bash
cd "$(dirname "$0")" || exit 1
./build.sh || { echo; read -r -p "Build failed. Press Enter to close..."; exit 1; }
open build/InputDeck.app
