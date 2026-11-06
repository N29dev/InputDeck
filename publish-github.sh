#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v git >/dev/null; then echo "Install Git first" >&2; exit 1; fi
if [ ! -d .git ]; then git init -b main; fi
if ! git remote get-url origin >/dev/null 2>&1; then
  git remote add origin https://github.com/N29dev/InputDeck.git
fi
git add .
if ! git diff --cached --quiet; then git commit -m "Update InputDeck"; fi
git push -u origin main
