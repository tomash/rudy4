#!/bin/bash
# ABI conformance audit for rudy's hand-written Ruby C API bindings.
#
# Compares the extern(C) declarations in src/rudy/bind/value.d against the
# symbols actually exported by libruby:
#   1. BOUND-AND-EXPORTED  — declaration resolves to a real symbol
#   2. BOUND-NOT-EXPORTED — declaration with no matching symbol (MISBIND
#                            candidates: typos, renamed/removed APIs)
#   3. EXPORTED-NOT-BOUND — exported rb_* API surface we have not bound
#                            (the unbound ledger; informative, not a failure)
#
# Symbol *names* are checked; widths/signatures (the rb_int2inum int-vs-long
# bug class) must be verified against ruby.h by hand — nm cannot see types.
#
# Usage: scripts/abi_audit.sh [path-to-ruby]
set -u

RUBY="${1:-ruby}"
BINDING=src/rudy/bind/value.d
OUT=.build/abi_audit
mkdir -p "$OUT"

LIBDIR=$("$RUBY" -e 'print RbConfig::CONFIG["libdir"]')
LIBRUBY=$(ls "$LIBDIR"/libruby*.so* 2>/dev/null | head -1)
if [ -z "$LIBRUBY" ]; then
    echo "ABI AUDIT FAIL: cannot locate libruby in $LIBDIR"
    exit 1
fi
echo "libruby: $LIBRUBY ($("$RUBY" -v))"

# Symbols bound in value.d: function decls (name directly before '(') and
# bound globals ('extern __gshared VALUE rb_...;'). Strip trailing '2'
# suffixes? No — rb_*2 are distinct real symbols; keep verbatim.
grep -vE '^\s*//' "$BINDING" | grep -oE 'rb_[a-z_0-9]+\(' \
  | sed 's/($//; s/(//' | sort -u > "$OUT/bound.txt"
grep -oE 'extern __gshared VALUE (rb_[a-zA-Z_0-9]+)' "$BINDING" \
  | sed 's/extern __gshared VALUE //' | sort -u >> "$OUT/bound.txt"
sort -u "$OUT/bound.txt" -o "$OUT/bound.txt"

# Symbols exported by libruby (defined only). Ruby 4 exports both rb_* API
# and internal ruby_* — we only audit the public rb_* surface here.
nm -D --defined-only "$LIBRUBY" 2>/dev/null \
  | awk '{print $NF}' | grep -E '^rb_[a-zA-Z_0-9]+$' | sort -u > "$OUT/exported.txt"

# --- report -------------------------------------------------------------
BOUND=$(wc -l < "$OUT/bound.txt")
echo "---"
echo "BOUND-AND-EXPORTED (resolved):"
comm -12 "$OUT/bound.txt" "$OUT/exported.txt" | tee "$OUT/ok.txt" | wc -l | xargs echo "  count:"
echo "BOUND-NOT-EXPORTED (MISBIND candidates):"
comm -23 "$OUT/bound.txt" "$OUT/exported.txt" | tee "$OUT/misbind.txt"
MIS=$(wc -l < "$OUT/misbind.txt")
echo "  count: $MIS"
echo "EXPORTED-NOT-BOUND (unbound ledger, top 60 of $(grep -cv '^$' "$OUT/exported.txt")):"
comm -13 "$OUT/bound.txt" "$OUT/exported.txt" > "$OUT/unbound.txt"
grep -cv '^$' "$OUT/unbound.txt" | xargs echo "  total unbound:"
head -60 "$OUT/unbound.txt"

echo "---"
if [ "$MIS" -gt 0 ]; then
    echo "ABI AUDIT FAIL: $MIS bound symbol(s) not exported by libruby ($BINDING vs $LIBRUBY)"
    exit 1
fi
echo "ABI AUDIT PASS: all $BOUND bound symbols resolve in libruby"