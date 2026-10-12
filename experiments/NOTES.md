# Experiments — Findings & Notes

Eight torture tests, all passing (`make exp-test`):

| # | Experiment | What it tortures |
|---|------------|------------------|
| 1 | `exp_wrap` | Wrapping a D struct (`DMatrix`) as a Ruby object: `rb_data_object_wrap` + free callback, `rb_define_alloc_func`, `rb_obj_id`-keyed D-side registry, GC stress (100k wraps, RSS delta) |
| 2 | `exp_cross` | Two-way boundary crossing: D calls Ruby blocks (`rb_funcall_with_block`), D builds Arrays and calls Ruby methods back, `rb_protect` catching a Ruby raise across 50 D frames, shoelace polygon math with D↔Ruby data flow |
| 3 | `exp_perf` | Perf: pure-D fib(28) in ~4ms, boundary-crossing fib(18) (~2.9ms, every level re-enters Ruby), 100k Float array build, 10k-entry D AA → Ruby Hash |
| 4 | `exp_http` | GVL-released blocking I/O: a hand-written TCP server loop in pure D running with the GVL released (`rb_thread_call_without_gvl`), D thread writing to a Ruby `Queue`, `rb_syserr_new` from `errno`, two Ruby threads hammering the server concurrently (11 assertions) |
| 5 | `exp_gcstorm` | GC storm at the D↔Ruby seam: 48,100 malloc'd TypedData wrappers crossing the boundary while a D churn thread allocates and `GC.collect()`s in a loop; exact free-count accounting, alloc/free balance == 0 (no leak, no double free), idempotent churn control (9 assertions) |
| 6 | `exp_exc` | Exception ping-pong: `rb_rescue`/`rb_ensure`/nested `rb_protect`, 50-level D↔Ruby mutual recursion with a raise at the bottom and rescue at the top, `rb_exc_raise` re-raising the *same* exception VALUE (identity check), all D-side counters intact after every longjmp unwind (19 assertions) |
| 7 | `exp_compact` | GC compaction vs wrapped structs and registered globals: `GC.compact` moves ~1.4k objects while TypedData wrappers hold references to them. Negative control (no callbacks) collects referents and crashes the VM; guarded wrapper (`dmark`=`rb_gc_mark_movable` + `dcompact`=`rb_gc_location` rewrite) survives with identity preserved. Registered globals via `rb_gc_register_address` + `rb_gc_location` refresh (8 assertions + subprocess witness) |
| 8 | `exp_convert` | Conversion-layer round trips: integers at ±2^63/2^64-1 boundaries, NaN/±0.0/inf, empty/NUL/binary/EUC-JP strings, frozen strings, 200-case binary fuzz, GC.stress mid-conversion, truthiness edges, hostile coercions (298 assertions; findings #12–#15) |

## Bugs found by the torture tests (and fixes)

1. **`VALUE` is aliased to `ulong` → `def!` raw-passthrough swallows `ulong` params.**
   **FIXED** (issue #1): in `rudy/defs.d`, `is(P[i] == VALUE)` used to pass the
   raw tagged VALUE to any `ulong` param (Ruby `5` arrived as `11`; fib(28)
   silently computed F(57)). Passthrough is now opt-in via `Raw!T` params;
   plain `ulong` params decode via `d_type!ulong` (rb_num2ulong). Regression
   tests: `identity_ulong`, `double_it_ulong`, `raw_value_id` in the
   acceptance suite (test/run.rb).

2. **`rb_data_object_get` is an inline C macro, not an exported symbol.**
   Can't be called from D. Fix in `exp_wrap`: D-side registry
   (`Matrix*[ulong]` keyed by `rb_obj_id`, reverse map, cleaned in the free
   callback). Library fix shipped: `rudy/typeddata.d` — a TypedData helper
   (`RudyTypedData!(T, "name")` mixin: `name_type` descriptor,
   `name_wrap`, `name_get` via `rb_data_typed_object_wrap` /
   `rb_check_typeddata`), acceptance-tested in `src/dtypetest.d` +
   `test/typedtest.rb` (9 assertions, incl. 100k-cycle GC stress).

3. **Uninitialized `double x;` in D is NaN** — not 0.0. Hit this **three
   separate times** (`det`, `cross_sum`, `perf_build total`): any `double`
   accumulator must be explicitly initialized (`= 0.0`).

4. **Instance ivars can't live on a Module.** `rb_iv_get(mod, "@klass")` on a
   module object segfaulted at 0x8c under stress. Fix: module-scope D globals
   (`dmatrix_class`, `expwrap_keep` keep-array) set in `Init_*` and rooted
   via `rb_gc_register_address`.

5. **`Array#sort` takes a block, not a positional Proc argument.** Needed
   `rb_funcall_with_block(ary, rb_intern("sort"), 0, null, blk)` — that symbol
   had to be bound in `value.d` (it wasn't in the original binding set).

6. **D module-level variables are thread-local by default; Ruby threads are
   OS pthreads** (exp_http). A module var written by a D helper thread was
   invisible to the Ruby thread that read it. Fix: `__gshared` for any
   module state shared across threads.

7. **A D exception escaping a `rb_thread_call_without_gvl` callback aborts
   the whole D runtime** (exp_http). D exceptions must never unwind through
   extern(C) frames into Ruby-managed code. Fix: try/catch *inside* the
   callback; record the failure; re-raise Ruby-side after the GVL is
   re-acquired.

8. **`cast(TcpSocket)` on `Socket.accept()`'s result is a runtime-checked
   downcast**, which returned null for the accepted connection class and
   segfaulted on first use (exp_http). Fix: type the accepted socket as the
   base `Socket`, not the subclass.

9. **GDC .so files dlopen'd by Ruby never run D's `rt_init()`** (exp_gcstorm).
   The D GC lazy-initializes on first `new`, so allocation "works", but
   `core.time`'s `_ticksPerSecond` is only filled by `_d_initMonoTime()`
   from rt_init — the first `GC.collect()` or `Thread.sleep` from a D thread
   hard-aborts: "MonoTimeImpl failed to get the frequency of the system's
   monotonic clock" (SIGABRT racing the Ruby VM; the process dies).
   Backtrace confirmed: churn_loop → ConservativeGC.fullCollect →
   MonoTimeImpl.currTime → abort. **Fix: `import core.runtime : rt_init;
   rt_init();` at the top of `Init_*`** in every dlopen'd extension.

10. **`RudyTypedData`'s wrap function hard-codes `&name_type`** (exp_gcstorm).
    Copying the generated descriptor and overriding `.dfree` on the copy
    does nothing — `name_wrap` still wraps with the original descriptor, so
    a custom free callback was never invoked (free_count stayed 0 while the
    storm ran). Fix: the mixin takes the free callback as an optional third
    template parameter — `    mixin RudyTypedData!(StormCell, "stormcell",
    &stormcell_free);` (the free function must be declared before the
    mixin; a leftover duplicate plain `mixin RudyTypedData!(...)` line caused
    conflicting-symbol compile errors and was removed).

11. **A wrapped struct holding live VALUEs with no `dmark` lets Ruby's GC
    collect the referents while the wrapper is alive** (exp_compact). Even
    a *compaction-only* stress exposes it: after `GC.compact`, reading a
    surviving unguarded box returned a `Module` and an unrelated
    `String` ("VariableNameChecker") — freed VALUE slots reused by other
    objects. Under GC.start+compact+churn the dangling VALUE is worse than
    garbage: `read_box` segfaults (`id_table_lookup` on a dangling VALUE →
    SIGSEGV) or glibc-aborts (`free(): invalid pointer`).
    **Fix: the `RudyTypedData` mixin now takes optional mark/compact
    callbacks** (`mixin RudyTypedData!(BoxCell, "gboxcell", &rudy_typed_free,
    &boxcell_mark, &boxcell_compact);`) wired into the descriptor's
    `d_mark`/`d_compact`. The movable-objects protocol: mark with
    `rb_gc_mark_movable` (NOT `rb_gc_mark`, which pins the referent and
    defeats compaction), rewrite references in the compact callback with
    `rb_gc_location`. Verified: guarded boxes keep referents alive and
    identical (same `object_id`) across full GCs + compactions + churn.
    Bonus finding: **fork() is not safe with a dlopen'd D .so** — the
    child's abort poisoned the parent too (D runtime state does not
    survive fork); the corruption witness therefore runs as a re-exec'd
    subprocess (`system()`), not `fork()`.

12. **`d_type!string` sliced a CHARACTER count as BYTES.**
    `rb_str_strlen` returns an encoding-aware char count; `ptr[0..len].idup`
    truncated every multibyte string ("héllo" = 6 bytes / 5 chars arrived as
    4 bytes; EUC-JP lost ~40% of its data). Found by inspection, pinned by
    exp_convert. **FIXED**: byte length now comes from Ruby itself —
    `rb_funcallv(str, "bytesize")` with a lazily-interned ID. Sub-finding:
    the natural fix `rb_str_bytes_len` is inline-macro-only, NOT exported
    (symbol-lookup crash at dlopen locally; `scripts/abi_audit.sh` would
    have caught it in CI — never bind a name you have not nm-verified).

13. **int/uint params decoded through unchecked wide paths.**
    The static-if chain tested `is(T : C_longlong)` (subtype) before any
    exact int branch, so `d_type!int` ran `rb_num2long` + cast: 2^31
    silently wrapped to -2147483648, 2^100 to garbage. Property tests
    also exposed the family's float behavior: `rb_num2long(42.5) == 42`
    (truncation, same as Ruby's own Integer()) and negatives wrapping
    2's-complement style through the unsigned converters. **FIXED**:
    exact types decode first through the range-checked EXPORTED converters
    `rb_num2int`/`rb_num2uint` (RangeError on overflow, FloatDomainError
    on NaN/inf — NUM2INT semantics), and every unsigned target rejects
    negatives via `rudy_check_unsigned` (sign probed through rb_num2dbl,
    because rb_num2long itself raises on 2^64-1).

14. **`d_type!bool` decoded as `val == Qtrue_`.**
    Ruby considers `0`, `0.0`, `""`, `[]`, `:sym` truthy (RUBY_TEST);
    they decoded as D `false`, breaking the invariant "arguments convert
    the way Ruby sees them". **FIXED**: `val != Qnil_ && val != Qfalse_`
    (RUBY_TEST semantics); all truthiness edges pinned in exp_convert.
    Documented: a `bool` param of a def!'d function means "Ruby
    truthiness", not "exactly true".

15. **`to_ruby_value!ulong` encoded through the SIGNED path.**
    `rb_ll2inum(cast(long) 2^64-1)` produced -1 (round trip FAILED for
    the top half of the ulong domain). Found by the exp_convert round
    trip on 18446744073709551615. **FIXED**: unsigned encode branch via
    the exported `rb_ull2inum` (nm-verified before binding).

## ABI conformance audit (scripts/abi_audit.sh)

`scripts/abi_audit.sh` diffs the `extern(C)` declarations in
`rudy/bind/value.d` against the symbols exported by libruby (via `nm -D`).
It fails CI on any *bound-but-not-exported* symbol. Names only — widths
and signatures (the `rb_int2inum` int-vs-`C_long` bug class) must still be
checked against `ruby.h` by hand; `nm` cannot see types.

First run (2026-10-11, ruby 4.0.7) found 8 phantom declarations, all unused:

- `rb_eSystemStackError` — **never existed**; the symbol is
  `rb_eSysStackError` (real misbind, the audit's first catch)
- `rb_define_method_under` — invented; no such API
- `rb_ary_size`, `rb_hash_keys`, `rb_hash_values` — inline/macro-only in
  headers (`RARRAY_LEN` etc.), never exported
- `rb_str_new2` — `#define rb_str_new2 rb_str_new_cstr`; bind the latter
- `rb_check_arity`, `rb_data_object_get` — inline-only in
  `ruby/internal/*`, not callable from a separately-linked `.so`

All eight removed from `value.d` (kept as comments where the API still
matters). Post-fix: **126 bound, 0 misbinds, 1410 unbound** (see
`.build/abi_audit/unbound.txt` for the full unbound ledger — includes lots
of internal/underscore names that are not for extension use).

## API gaps worth adding to the library

Verified exported by libruby but **not yet bound** in `rudy/bind/value.d`:

- ~~`rb_yield_block`, `rb_block_call`~~ — bound; exercised in exp_cross /
  dexitest
- ~~`rb_rescue`, `rb_ensure`~~ — bound; tortured in exp_exc (rb_protect was
  already there)
- ~~`rb_check_typeddata`, `rb_data_object_zalloc`, `rb_data_typed_object_wrap`~~
  — bound in `rudy/bind/value.d` + `RudyTypedData` helper in `rudy/typeddata.d`
  (see finding 2)
- ~~`rb_define_singleton_method`~~ — bound; exercised in dexitest
- ~~GVL/GC APIs: `rb_thread_call_without_gvl`, `rb_thread_call_without_gvl2`~~
  — bound; exp_http runs a D server loop with the GVL released
- ~~`rb_str_new` variadic family, `rb_num2*` conversion family~~ — variadic
  (argc/argv) trampoline shipped in `rudy/defs.d` (optional args via D
  default values), exercised in dexitest

Newly bound for the torture experiments (all in `rudy/bind/value.d`):

- `rb_ull2inum`, `rb_uint2inum` — unsigned encode path for ulong/C_ulonglong
  (finding #15: rb_ll2inum(cast(long)) turned 2^64-1 into -1)
- `rb_num2int`, `rb_num2uint` — the range-checked EXPORTED converters
  (finding #13: NUM2INT semantics, RangeError on overflow); note their
  _inline variants exist in headers but were NOT needed
- `rb_obj_is_instance_of` — the exported way to type-test without the
  rb_type macro (used for float detection before numeric coercion)
- DELIBERATELY NOT bound: `rb_str_bytes_len` — inline-macro-only in
  rstring.h, NOT exported (dlopen symbol-lookup crash; see finding #12).
  Byte length goes through String#bytesize via rb_funcallv instead.

- `rb_exc_raise` — re-raise the *same* exception VALUE from D (noreturn;
  callers need `assert(0)` after it to satisfy GDC's no-return analysis)
- `rb_int2inum` — ABI fix: the C header declares `intptr_t`, the old binding
  said `int`; it silently worked through register reuse but is now `C_long`
- `rb_errinfo` / `rb_set_errinfo` — inspect/clear Ruby's current exception
  state from D (used by exp_exc's nested-protect torture)
- `rb_gc_location`, `rb_gc_mark`, `rb_gc_mark_movable`, `rb_gc_register_address`,
  `rb_gc_unregister_address` — GC rooting/movable-objects protocol (exp_compact;
  see finding 11)

Still missing / future work:

- `rb_yield` family beyond what's bound; `rb_block_call` with data

## Perf observations (Ruby 4.0.7, GDC-14, -O2)

- Pure D fib(28) → 317811 in ~4.3 ms (naive tree recursion, no memo).
- fib(18) with a Ruby boundary crossing at *every* recursion level: ~2.9 ms.
  Boundary overhead is real but modest.
- 100k-element Float array build: ~5 ms.
- 10k-entry D AA converted to Ruby Hash: ~5.6 ms, values verified (i*i).
- After 100k wrap/unwrap/free cycles: RSS delta ~32 MB retained by the D
  runtime (D GC doesn't promptly return freed object memory to the OS).
  Documented as expected behavior, not a leak per se.
- exp_gcstorm: 48,100 TypedData wraps allocated, all freed exactly once
  (atomic-counted dfree); alloc/free balance 0 across 8 concurrent Ruby
  threads racing a D churn thread doing `new` + `GC.collect()` in a loop.

## GDC-14 quirks catalog (from all six experiments)

- Module variables are thread-local unless `__gshared`/`shared`.
- `shared` counters need `atomicOp!"+="` (requires a `shared ref`); a plain
  read for format is fine but `cast(ulong)` it explicitly.
- `core.thread.Thread`'s constructor takes a plain `void function()`, not
  an `extern(C)` function.
- D exceptions must never escape an extern(C) frame or a no-GVL callback —
  catch in D, re-raise Ruby-side after re-acquiring the GVL.
- noreturn Ruby APIs (`rb_raise`, `rb_exc_raise`) need `assert(0)` after the
- A Ruby raise (rb_raise longjmps) is NOT a D exception: try/catch in an
  extern(C) body cannot intercept it, and D exceptions must never cross
  back into Ruby. Validate before raising, or let Ruby see the raise at
  its own boundary (exp_convert verified depth-2 raise/rescue).
  call — GDC's no-return analysis flags functions that "fall off the end"
  otherwise.
- `import` statements can't appear mid-function; put them at module scope
  or at the top of the enclosing scope block.
- Mixin-template instantiations must be unique — a leftover duplicate
  `mixin RudyTypedData!(...)` line (same T+name) produces conflicting-symbol
  compile errors.
- A .so extension dlopen'd by Ruby **must call `rt_init()` itself** (see
  finding 9) — nothing runs D's runtime init for you.

## Build/test commands

```sh
make exp            # build experiments
make exp-test       # run all eight experiment suites
ruby test/run.rb    # core dextest suite
```