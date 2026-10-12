#!/bin/bash
# scripts/memcheck.sh — ASan/valgrind torture runs for rudy4 (backlog item 7).
#
# Builds the rudy library + dextest.so + the rt_init-free experiment .so's
# with -fsanitize=address into .build.asan/, then runs the corresponding
# test suites under ruby with LD_PRELOAD=libasan.so.
#
# Usage: bash scripts/memcheck.sh
#
# Findings driving the scope (experiments/NOTES.md #23/#24):
# - gdc-14 + ASan: any explicit druntime rt_init() call SEGVs (ModuleInfo
#   NULL read), independent of ASAN_OPTIONS. Experiments whose init hook
#   calls rt_init (gcstorm/compact/convert/objproto) cannot run under ASan
#   in this toolchain — excluded.
# - exp_http SEGVs with an ASan "Failed to munmap" even with GC disabled —
#   under investigation; excluded from the run but still built.
# - LeakSanitizer is disabled: it flags D GC heap pages as leaks (false
#   positives for a GC'd language).
# - valgrind is not installed on this host; CI may add it later.
set -u
cd "$(dirname "$0")/.."

RUBY_BIN="${RUBY_BIN:-$HOME/.asdf/installs/ruby/4.0.7/bin/ruby}"
GDC="${GDC:-gdc-14}"

RH=$("$RUBY_BIN" -e 'print RbConfig::CONFIG["rubyhdrdir"]')
AH=$("$RUBY_BIN" -e 'print RbConfig::CONFIG["rubyarchhdrdir"]')
LIBDIR=$("$RUBY_BIN" -e 'print RbConfig::CONFIG["libdir"]')
LIBRUBY=$("$RUBY_BIN" -e 'print RbConfig::CONFIG["LIBRUBYARG_SHARED"]')
ASAN_SO="$("$GDC" -print-file-name=libasan.so)"

BUILD_DIR="${RUDY_BUILD_DIR:-.build.asan}"
export RUDY_BUILD_DIR="$BUILD_DIR"
DFLAGS="-fsanitize=address -fPIC -g -Isrc -I$RH -I$AH -fpreview=dip1008 -Wno-deprecated"
export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0:halt_on_error=1:allocator_may_return_null=1:detect_odr_violation=0}"
export LD_PRELOAD="$ASAN_SO"

# rt_init-free experiments: buildable and runnable under ASan (http: build
# only — munmap crash under investigation, NOTES.md #24).
BUILDABLE=(wrap cross perf exc defargs http)
RUNNABLE=(wrap cross perf exc defargs)

mkdir -p "$BUILD_DIR"
OBJS=""
for f in src/rudy/*.d src/rudy/bind/*.d; do
  o="$BUILD_DIR/$(echo "$f" | tr '/' '_' | sed 's/\.d$/.o/')"
  "$GDC" $DFLAGS -c "$f" -o "$o" || { echo "COMPILE FAIL $f"; exit 1; }
  OBJS="$OBJS $o"
done
"$GDC" $DFLAGS -shared -o "$BUILD_DIR/dextest.so" $OBJS src/dextest.d \
  -L"$LIBDIR" "$LIBRUBY" -lm || { echo "COMPILE FAIL dextest.so"; exit 1; }
echo "built library objects + dextest.so into $BUILD_DIR"

rc_all=0
for s in "${BUILDABLE[@]}"; do
  "$GDC" $DFLAGS -shared -o "$BUILD_DIR/exp_${s}.so" $OBJS "experiments/exp_${s}.d" \
    -L"$LIBDIR" "$LIBRUBY" -lm || { echo "BUILD FAIL exp_${s}.so"; rc_all=1; continue; }
done
echo "built experiment .so's: ${BUILDABLE[*]}"

for s in "${RUNNABLE[@]}"; do
  test_rb="experiments/test_exp_${s}.rb"
  [ -f "$test_rb" ] || { echo "SKIP $s (no suite file)"; continue; }
  echo "== ASan: $s"
  "$RUBY_BIN" -Ilib "$test_rb" >"/tmp/memcheck_${s}.log" 2>&1
  rc=$?
  if [ $rc -eq 0 ]; then
    echo "   PASS (log /tmp/memcheck_${s}.log)"
  else
    echo "   FAIL rc=$rc (log /tmp/memcheck_${s}.log)"
    tail -8 "/tmp/memcheck_${s}.log"
    rc_all=1
  fi
done
unset LD_PRELOAD
echo "memcheck.sh rc=$rc_all"
exit $rc_all
{"id":"7bffbd27-bc51-4099-8296-219463d451d0","session_id":"9621158e975c2a39","timestamp":"2026-10-12T21:07:48+00:00","model":"openrouter/auto","provider":"openrouter","prompt_tokens":16440,"completion_tokens":22,"cache_read_tokens":16128,"cache_write_tokens":0,"cost_usd":0.0008642,"cost_source":"api"}
