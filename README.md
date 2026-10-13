# rudy4

[![Gem Version](https://img.shields.io/gem/v/rudy4.svg)](https://rubygems.org/gems/rudy4)
[![Gem Downloads](https://img.shields.io/gem/dt/rudy4.svg)](https://rubygems.org/gems/rudy4)
[![CI](https://github.com/tomash/rudy4/actions/workflows/ci.yml/badge.svg)](https://github.com/tomash/rudy4/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Write Ruby native extensions in D.** A from-scratch rewrite of
[rudy](https://github.com/tomash/rudy) (2010), targeting **Ruby 4.0** and
**GDC 14 (D front-end 2.10x)**.

Already on RubyGems — scaffold and build a working D-backed extension gem in
under a minute:

```sh
gem install rudy4
rudy4 doctor              # verify Ruby + GDC toolchain (compiles a probe)
rudy4 init fast_math      # write a small, self-contained extension gem
cd fast_math && rake compile && rake test
```

See [Getting started](#getting-started-the-rudy4-gem) for the details.

The 2010 original bound Ruby 1.8's C API via a bcd.gen-generated `ruby.d`,
required a separate `meta/` template-metaprogramming library, and built with
the long-dead `dsss` tool. This repo keeps the one idea worth keeping —
`def!` — and drops everything else.

## The idea: `def!`

Register a D function as a Ruby method with automatic argument conversion:

```d
module myext;

import rudy.defs;

long add_five(long n) { return n + 5; }

pragma(mangle, "Init_myext")
extern(C) void Init_myext()
{
    def!(add_five);            // global function (on Object)
    def!("MyClass", add_five); // instance method of MyClass
}
```

From Ruby:

```ruby
require "myext"
add_five(37)   # => 42
```

Compile the extension into a `myext.so` Ruby can `require` (here `myext.d`
lives next to a `src/` tree with the library):

```sh
gdc -shared -o myext.so \
  -fPIC -Isrc \
  $(ruby -e 'print RbConfig::CONFIG["rubyhdrdir"]') \
  $(ruby -e 'print RbConfig::CONFIG["rubyarchhdrdir"]') \
  src/rudy/*.d src/rudy/bind/*.d myext.d \
  $(ruby -e 'print RbConfig::CONFIG["LIBRUBYARG_SHARED"]') \
  -Wl,-rpath,$(ruby -e 'print RbConfig::CONFIG["libdir"]') -lm
```

or just `make` with this repo's Makefile, which does the same (header dirs,
`libruby` and rpath are pulled from `RbConfig`), builds `dextest.so` from
`src/dextest.d`, and `make test` runs the acceptance suite.

Arguments arrive as raw `VALUE`s and are converted to the declared D
parameter types (`long`, `double`, `string`, `bool`, ...); the return
value is converted back. No manual `rb_num2long` boilerplate — the
trampoline does it.

Supported D parameter types: `bool`, `int`/`uint`/`long`/`ulong` (`C_long`
aliases follow the platform), `double`, `string` (copied via `idup`),
static and dynamic arrays, and hashes (AAs). Return types: all of the
above plus `cdouble`/`creal` (mapped to Ruby `Complex` via `rb_funcallv`).
To receive a raw, unconverted `VALUE`, declare the parameter (or return
type) as `Raw!VALUE` — passthrough is opt-in since `VALUE` is an `ulong`
alias and a plain `ulong` param means "decode me".

Conversion semantics worth knowing (pinned by `exp_convert`):
- `bool` follows **Ruby truthiness** (`nil`/`false` → `false`, everything
  else — including `0` and `""` — → `true`), matching how Ruby itself
  sees the argument.
- `string` decodes the full byte content (`String#bytesize` bytes), not
  the character count — multibyte and binary strings survive intact.
- `int`/`uint` decode through the range-checked converters: out-of-range
  values raise `RangeError` instead of silently wrapping; unsigned D
  types also reject negative inputs.

### D gotchas

The torture experiments found **twenty-four** D-specific traps; the full catalog
with fixes lives in experiments/NOTES.md. The ones that will bite you on
day one:

- **Uninitialized `double x;` is NaN** — not 0.0 (D's `float.init` is NaN).
  Always write `double x = 0.0;` for accumulators; a NaN accumulator
  silently poisons every sum that touches it. This bit three separate
  times in the torture tests.
- **A .so extension dlopen'd by Ruby never runs D's `rt_init()`** — the D
  GC lazy-initializes so allocation appears to work, but the first
  `GC.collect()` or `Thread.sleep` from D hard-aborts. Call
  `import core.runtime : rt_init; rt_init();` at the top of `Init_*`.
- **Module variables are thread-local by default** — Ruby threads are OS
  pthreads, so shared state needs `__gshared`.
- **D exceptions must never escape an extern(C) frame** (or a
  no-GVL callback) — catch in D, raise Ruby-side after re-acquiring the GVL.
- **Uninitialized integers and pointers are fine (0/null).**
- **gdc-14 + `-fsanitize=address` crashes on any explicit `rt_init()`**
  (ModuleInfo NULL SEGV, finding #23) — ASan coverage is limited to the
  rt_init-free experiments, which pass clean (`make memcheck`, finding #24).

## Wrapping D structs: `RudyTypedData`

`def!` converts *arguments*, but sometimes you want the D struct itself to
*be* a Ruby object (stateful objects, not just pure functions). The old
`Data_Wrap_Struct` path needs `rb_data_object_get`, which is an inline C
macro — uncallable from D. The TypedData API avoids that entirely:

```d
import rudy.typeddata;

struct Matrix { size_t rows, cols; double* data; }

mixin RudyTypedData!(Matrix, "matrix");
// generates: matrix_type (rb_data_type_t descriptor),
//            matrix_wrap(VALUE klass, Matrix*),
//            matrix_get(VALUE obj)   // raises TypeError on wrong type

extern(C) VALUE matrix_alloc(VALUE klass)
{
    import core.stdc.stdlib : calloc;
    return matrix_wrap(klass, cast(Matrix*) calloc(1, Matrix.sizeof));
}
```

The mixin generates the descriptor (dfree defaults to `free()` for
malloc'd structs; pass `&rudy_typed_nofree` for D-GC-owned memory, or any
custom `extern(C) void function(void*)` for cleanup). `matrix_get` uses
`rb_check_typeddata`, so unwrapping a non-Matrix raises `TypeError` — no
D-side registry needed. Full example (alloc func, `initialize`, `[]`/
`[]=`, `det`, `to_a`, 100k-object GC stress): `src/dtypetest.d`, suite:
`test/typedtest.rb` (9 assertions).

### Optional arguments via D default values

A `def!`'d function whose parameters declare D default values is
registered with arity `-1` and gets a variadic (argc/argv) trampoline:
missing arguments are substituted with their declared defaults, so from
Ruby the trailing parameters behave like optional arguments.

```d
long var_sum(long a, long b = 2, long c = 30) { return a + b + c; }
def!("MyModule", var_sum);
```

```ruby
MyModule.var_sum(1)      # => 33   (b, c defaulted)
MyModule.var_sum(1, 2)   # => 33   (c defaulted)
MyModule.var_sum(1, 2, 0) # => 3
MyModule.var_sum         # ArgumentError (a is required)
```

Raw `VALUE` parameters (and `VALUE` returns via `to_ruby_value`) pass
through untouched, so D functions can mix optional and raw-VALUE args.

### Blocks, `*rest`, `**kwargs`, `Self`, and visibility

Special parameters are filled by the trampoline itself, never decoded
from argv (at most one of `Rest`/`KwArgs`/`RubyBlock` per function;
`RubyBlock` must be the last parameter; declaring one switches the
registration to the uniform argc/argv trampoline):

```d
import rudy.args;
import rudy.convert;

long with_block(long n, RubyBlock blk)
{
    if (!blk.given) return n;
    return blk.call(n);              // yields n, returns block result
}

long rest_sum(long first, Rest rest) // var_sum(1, 2, 3) -> rest = [2, 3]
{
    long total = first;
    foreach (v; rest) total += d_type!long(v);
    return total;
}

string kw_pick(KwArgs kw)            // kw_pick(n: 5) / kw_pick()
{
    long n = kw.get!long("n", 0);    // D default when the key is absent
    import std.conv : to;
    return "n=" ~ to!string(n) ~ (kw.given ? " (given)" : "");
}
```

Semantics pinned by `exp_defargs` (44 assertions):

- `RubyBlock.call` with no block given raises `LocalJumpError` —
  the same contract as `yield`. `given` tells the two cases apart;
  calling other `def!`'d D methods from inside a block body works
  (reentrancy).
- A `Rest` of zero args is an **empty array**, not `nil` — matching
  Ruby's own `*rest` semantics (`length == 0`, `empty` agrees).
- KwArgs keys arrive as Symbols; `kw.to!(V, string)` normalizes them
  via `to_s`. Decode values into concrete D types
  (`kw.to!(long, string)`); to walk values untouched use
  `kw.to!(Raw!VALUE, string)` — a plain `VALUE`/`ulong` V would run a
  numeric decode over every value and raise on non-numbers.
- Visibility and singletons: `def_private!`/`def_protected!` define
  instance-level methods (probe through `Object.new.extend(Mod)` or
  `send`), `def_singleton!` a class-level method, `def_singleton_on!`
  attaches to one specific object (`"Mod::CONST"` paths walk the scope
  chain). `Self` receives the actual receiver.
- Returning a Ruby object built in D requires a `Raw!VALUE` return
  (finding #17): a plain `VALUE` return is converted as a machine word.

## Beyond def! — direct C-API bindings

`src/rudy/bind/value.d` also binds the pieces you need to write
extension methods by hand (extern(C) bodies registered directly):

- **Blocks/iteration**: `rb_yield`, `rb_yield_values2`, `rb_yield_splat`,
  `rb_block_call` (C-implemented blocks!), `rb_block_given_p`, `rb_each`
- **Structured exceptions**: `rb_rescue` (single StandardError family),
  `rb_ensure`, `rb_protect`, `rb_exc_raise` (re-raise the *same* exception
  VALUE), `rb_errinfo`/`rb_set_errinfo`
- **Per-object methods**: `rb_define_singleton_method`
- **GVL**: `rb_thread_call_without_gvl` / `_with_gvl` (pure-D work can
  release the GVL so other Ruby threads run), `RUBY_UBF_IO`
- **Arg scanning**: `rb_scan_args` (argc/argv style)

`src/dexitest.d` + `test/exitest.rb` exercise all of these (31
assertions) alongside the fixed-arity `def!` suite; the exception and
GVL bindings are additionally tortured by `experiments/exp_exc` and
`experiments/exp_http` (see experiments/NOTES.md).

## Layout

```
lib/rudy4/              the rudy4 gem: CLI, generator, doctor, templates
bin/rudy4               the rudy4 command
vendor/rudy/            vendored copy of src/rudy/ (shipped in the gem)
rudy4.gemspec           the gem itself
scripts/vendor_sync.sh  src/rudy/ -> vendor/rudy/  (vendor_check.sh guards drift)
src/rudy/bind/value.d   hand-written binding to the Ruby 4.0 C API
src/rudy/convert.d      to_ruby_value!(T) / d_type!(T) conversions
src/rudy/defs.d         def! templates + extern(C) trampolines
src/rudy/typeddata.d    RudyTypedData mixin: wrap D structs as Ruby objects
src/rudy/objproto.d     RudyObjectProtocol mixin: dup/clone/==/hash/inspect/freeze
src/dextest.d           acceptance-test extension (old "dexter" revived)
src/dexitest.d          missing-API bindings acceptance extension
src/dtypetest.d         typed-data acceptance extension
experiments/           eleven torture experiments (see experiments/NOTES.md)
examples/hello_gem/    gem-shaped extension example (gemspec + ext/ + lib/)
test/rudy4_test.rb      the gem's own suite (scaffold / doctor / vendor)
test/run.rb             Ruby-side acceptance suite (22 assertions)
test/exitest.rb         bindings acceptance suite (31 assertions)
test/typedtest.rb       typed-data acceptance suite (9 assertions)
```

`src/rudy/bind/value.d` is deliberately **not** generated: the modern Ruby
API is mostly opaque `VALUE` + function calls, so ~200 lines of hand-picked
`extern(C)` declarations replace the old 2,400-line bcd.gen blob. Struct
accesses (`RSTRING(str).ptr`) are gone — everything goes through exported
functions (`rb_string_value_ptr`, `rb_float_value`, `rb_ary_entry`, ...).

## Getting started: the `rudy4` gem

The fastest way in is the [`rudy4` gem on RubyGems](https://rubygems.org/gems/rudy4).
It scaffolds a self-contained extension gem — the rudy4 D library is copied
into it, so the project builds with nothing but GDC and your Ruby headers, no
checkout and no `RUDY4_ROOT`:

```sh
gem install rudy4
rudy4 doctor              # checks Ruby + headers + GDC, then compiles a probe
rudy4 init fast_math      # writes a small extension gem
cd fast_math
rake compile              # GDC builds ext/fast_math/fast_math.d
rake test                 # 7 assertions against the compiled extension
```

Now edit `ext/fast_math/fast_math.d` and repeat `rake compile && rake test`.
The generated project is a normal gem: add it to another app as a path gem,
or `gem build` and publish it — RubyGems will compile the D source at install
time.

`rudy4 doctor` is the thing to run when a build fails: it verifies the Ruby
toolchain, reports the GDC version, and then *proves* the setup by scaffolding
and compiling a throwaway extension, so a failure names the missing piece
instead of dumping compiler output.

## Requirements

- Ruby 4.0 (any install with `libruby` and headers)
- GDC ≥ 13 (tested: gdc-14 14.2.0, D front-end 2.10x)
- GNU make

## Packaging: shipping a D-backed gem

Two worked examples, in order of usefulness:

1. **`rudy4 init NAME`** (the `rudy4` gem, above) — the recommended path. It
   writes a project whose `ext/NAME/rudy/` is a *vendored copy* of the rudy4 D
   library, so it builds and installs with no reference to a rudy4 checkout.
2. **`examples/hello_gem/`** — the in-repo reference for what that generated
   layout can contain (wrapped D struct, object protocol, freeze-aware
   mutators). It predates the gem and finds its sources by walking up to a
   checkout (`RUDY4_ROOT`), so it is a development example, not the first-run
   path:

   ```sh
   cd examples/hello_gem
   bash test/smoke.sh                              # build + 17 assertions
   gem build hello_gem.gemspec
   RUDY4_ROOT=/path/to/rudy4 gem install ./hello_gem-0.1.0.gem
   ruby -e 'require "hello_gem"; puts add(2, 3)'
   ```

   See `examples/hello_gem/README.md` for how the extconf.rb trick works and
   why installing from outside the repo needs `RUDY4_ROOT`.

### The `rudy4` gem itself

`lib/rudy4/`, `bin/rudy4`, `vendor/rudy/` and `rudy4.gemspec` are the gem:
`init` (scaffolder), `doctor` (toolchain check + build probe), `vendor`
(re-copy the D library into an existing project). `vendor/rudy/` is generated
from `src/rudy/` by `scripts/vendor_sync.sh`; CI runs
`scripts/vendor_check.sh` and fails if the two drift, so `src/rudy/` stays the
single source of truth.

## Torture experiments (`experiments/`)

Eleven experiments probe the D↔Ruby seam far past what the acceptance
suites cover — GVL-released blocking I/O with a hand-written TCP server,
48k-object TypedData GC storms against a concurrent `GC.collect()` churn
thread, 50-level exception ping-pong with `rb_rescue`/`rb_ensure`/nested
`rb_protect` and `rb_exc_raise` identity, perf, conversion round trips
across every supported D type (integers at ±2^63/2^64-1, NaN/inf,
multibyte/binary/invalid-encoding strings, GC.stress at the seam), the
`def!` argument-passing machinery itself (blocks, `*rest`, `**kwargs`,
visibility, singletons), a full object protocol (`dup`/`clone`/`==`/
`hash`/`inspect`/`freeze`), and a non-regression suite for the documented
non-goals (Fiber switches, Ractor refusal, GVL-held interruptibility).
They found
nineteen real bugs (ABI widths, a missing `rt_init()`, thread-local-by-default module
state, a TypedData free-callback routing bug, ...) plus eight toolchain /
boundary findings (#20–#27: object-protocol semantics, the zalloc
size-arg bug, GDC template-arg quirks, the gdc-14 ASan/rt_init
limitations, and the three non-goals), all
documented with
fixes in **experiments/NOTES.md** — that file is the real catalog of
D-specific traps when writing Ruby extensions. Run them with `make exp`
then `make exp-test`.

## Known limitations (non-goals)

Three things rudy deliberately does **not** promise. Each is pinned by
`experiments/test_exp_nonregression.rb` so the boundary is evidence, not
silence (see NOTES.md findings #25–#27):

- **Fiber switching across D frames** — simple value round-trips across a
  `Fiber.yield` inside a D frame work, but a D-GC object reachable only
  from a fiber-stack local has no GC root (D's GC scans the thread stack,
  not Ruby's fiber stacks).
- **Ractor-shareability** — calling `def!`'d methods from a non-main
  Ractor is refused by the VM (`Ractor::UnsafeError`); D-wrapped objects
  are not shareable. Use threads or separate processes.
- **Interruptibility of a long GVL-held D call** — a pure-D call holding
  the GVL ignores Ctrl-C until it returns. Run long work under
  `rb_thread_call_without_gvl` (with a cooperating unblock function) and
  it becomes interruptible in milliseconds.

## Build & test

```sh
make           # builds .build/dextest.so, .build/dexitest.so and .build/dtypetest.so
make test      # runs test/run.rb + test/exitest.rb + test/typedtest.rb (62 assertions)
make exp       # builds the eleven experiment extensions (experiments/)
make exp-test  # runs all eleven torture suites (452 assertions, see experiments/NOTES.md)
make memcheck  # ASan subset: builds .build.asan and runs the rt_init-free suites

make gem-test       # the rudy4 gem's own suite (scaffold / doctor / vendor, 136 assertions)
make gem-test-full  # + scaffolds a project and compiles it with GDC, end to end
make vendor-check   # fails if vendor/rudy/ has drifted from src/rudy/
```

The Makefile finds Ruby via `ruby -e` hdrdir/libdir queries (works with
asdf, rbenv, system Ruby). Point `RUBY` at a specific binary if needed:

```sh
make test RUBY=~/.asdf/installs/ruby/4.0.7/bin/ruby
```

## Differences from 2010 rudy

| 2010 rudy | rudy4 |
|---|---|
| Ruby 1.8 | Ruby 4.0 |
| D1 | D2 (GDC 14) |
| `VALUE` = `uint` | `VALUE` = `ulong` (pointer-sized) |
| bcd.gen'd 2,415-line `ruby.d` | ~220-line hand-written binding |
| `RSTRING(s).ptr` struct access | function API only |
| `meta/` TMP library (~870 lines) | `std.traits` (`Parameters!`, `__traits`) |
| `dsss` build | plain Makefile |
| raw VALUE passthrough in def! | automatic D↔Ruby conversion |

## License

MIT — see [LICENSE](LICENSE) (as the original rudy).
