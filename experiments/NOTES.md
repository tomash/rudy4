# Experiments — Findings & Notes

Three torture tests, all passing (`make exp-test`):

| # | Experiment | What it tortures |
|---|------------|------------------|
| 1 | `exp_wrap` | Wrapping a D struct (`DMatrix`) as a Ruby object: `rb_data_object_wrap` + free callback, `rb_define_alloc_func`, `rb_obj_id`-keyed D-side registry, GC stress (100k wraps, RSS delta) |
| 2 | `exp_cross` | Two-way boundary crossing: D calls Ruby blocks (`rb_funcall_with_block`), D builds Arrays and calls Ruby methods back, `rb_protect` catching a Ruby raise across 50 D frames, shoelace polygon math with D↔Ruby data flow |
| 3 | `exp_perf` | Perf: pure-D fib(28) in ~4ms, boundary-crossing fib(18) (~2.9ms, every level re-enters Ruby), 100k Float array build, 10k-entry D AA → Ruby Hash |

## Bugs found by the torture tests (and fixes)

1. **`rb_data_object_get` is an inline C macro, not an exported symbol.**
   Can't be called from D. Fix in `exp_wrap`: D-side registry
   (`Matrix*[ulong]` keyed by `rb_obj_id`, reverse map, cleaned in the free
   callback). This is the main missing-API finding: rudy should ship a
   typed-data helper (wrap + unwrap + registry) as library code.

2. **`VALUE` is aliased to `ulong` → `def!` raw-passthrough defeats `d_type`.**
   In `rudy/defs.d`, `is(P[i] == VALUE)` exists so D funcs taking raw VALUEs
   work — but since `VALUE == ulong`, any D function with a `ulong` parameter
   gets the **tagged** VALUE passed through untouched (Ruby `5` arrives as
   `11`). This silently corrupted `perf_fib(ulong)` (fib(28) was actually
   computing F(57) — looked like a hang, was just astronomically slow).
   Workaround: take `long` (or any non-VALUE type) so `d_type` decodes.
   Library fix: make raw-passthrough opt-in (distinct `TypedValue` type or a
   `Raw` wrapper struct) instead of triggering on the alias.

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

## API gaps worth adding to the library

Verified exported by libruby but **not yet bound** in `rudy/bind/value.d`:

- `rb_yield_block`, `rb_block_call` — proper block/yield support (def! has no
  block plumbing at all)
- `rb_rescue`, `rb_ensure` — structured exception handling from D (only
  `rb_protect` is bound today)
- `rb_check_typeddata`, `rb_data_object_zalloc`, `rb_data_typed_object_wrap`
  — typed-data counterpart to finding #1
- `rb_define_singleton_method` — needed for per-object methods, not just
  module/class methods
- GVL/GC APIs: `rb_thread_call_without_gvl`, `rb_thread_call_without_gvl2`
  — required before any real threading story
- `rb_str_new` variadic family, `rb_num2*` conversion family — def! only
  supports fixed arity 0..3; **a variadic (argc/argv) trampoline is needed**
  for real-world methods

## Perf observations (Ruby 4.0.7, GDC-14, -O2)

- Pure D fib(28) → 317811 in ~4.3 ms (naive tree recursion, no memo).
- fib(18) with a Ruby boundary crossing at *every* recursion level: ~2.9 ms.
  Boundary overhead is real but modest.
- 100k-element Float array build: ~5 ms.
- 10k-entry D AA converted to Ruby Hash: ~5.6 ms, values verified (i*i).
- After 100k wrap/unwrap/free cycles: RSS delta ~32 MB retained by the D
  runtime (D GC doesn't promptly return freed object memory to the OS).
  Documented as expected behavior, not a leak per se.

## Build/test commands

```sh
make exp            # build experiments
make exp-test       # run all three experiment suites
ruby test/run.rb    # core dextest suite (17 assertions)
```