#!/usr/bin/env bash
# Fail if vendor/rudy/ has drifted from src/rudy/ (CI guard, and `rake
# vendor:check` locally). Runs vendor_sync.sh in a scratch copy so the working
# tree is never touched.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$HERE/vendor/rudy/defs.d" ]]; then
  echo "vendor_check: vendor/rudy/ is missing — run scripts/vendor_sync.sh" >&2
  exit 1
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

mkdir -p "$scratch/src" "$scratch/vendor"
cp -R "$HERE/src/rudy" "$scratch/src/rudy"
cp -R "$HERE/vendor/rudy" "$scratch/vendor/rudy"

mkdir -p "$scratch/scripts"
cp "$HERE/scripts/vendor_sync.sh" "$scratch/scripts/"

bash "$scratch/scripts/vendor_sync.sh" >/dev/null

if ! diff -r "$scratch/vendor/rudy" "$HERE/vendor/rudy" >/dev/null; then
  echo "vendor_check: vendor/rudy/ has drifted from src/rudy/ — run scripts/vendor_sync.sh" >&2
  diff -r "$scratch/vendor/rudy" "$HERE/vendor/rudy" || true
  exit 1
fi

echo "vendor_check: vendor/rudy/ is in sync with src/rudy/"
