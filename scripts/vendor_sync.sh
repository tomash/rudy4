#!/usr/bin/env bash
# Sync the vendored copy of the rudy4 D library (vendor/rudy/) from src/rudy/.
#
# The gem ships the D sources so a scaffolded extension builds without a rudy4
# checkout. `src/rudy/` stays the single source of truth; this script copies it,
# and `rake vendor:check` (run in CI) fails if the two have drifted.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$HERE/src/rudy"
DEST="$HERE/vendor/rudy"

if [[ ! -f "$SRC/defs.d" ]]; then
  echo "vendor_sync: source library not found at $SRC" >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST"
# -R preserves the rudy/bind/ nesting, which the `import rudy.bind.value;`
# module paths depend on.
cp -R "$SRC/." "$DEST/"

echo "vendor_sync: copied $(find "$DEST" -name '*.d' | wc -l | tr -d ' ') D sources into vendor/rudy/"
