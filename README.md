# rudy4

**Write Ruby native extensions in D.** A from-scratch rewrite of
[rudy](https://github.com/tomash/rudy) (2010), targeting **Ruby 4.0** and
**GDC 14 (D front-end 2.10x)**.

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
value is converted back. No `Data_Wrap_Struct`, no struct access, no
manual `rb_num2long` boilerplate — the trampoline does it.

Supported D parameter types: `bool`, `int`/`uint`/`long`/`long` (`C_long`
aliases follow the platform), `double`, `string` (copied via `idup`),
static and dynamic arrays, and hashes (AAs). Return types: all of the
above plus `cdouble`/`creal` (mapped to Ruby `Complex` via `rb_funcallv`).

## Layout

```
src/rudy/bind/value.d   hand-written binding to the Ruby 4.0 C API
src/rudy/convert.d      to_ruby_value!(T) / d_type!(T) conversions
src/rudy/defs.d         def! templates + extern(C) trampolines
src/dextest.d           acceptance-test extension (old "dexter" revived)
test/run.rb             Ruby-side acceptance suite (17 assertions)
```

`src/rudy/bind/value.d` is deliberately **not** generated: the modern Ruby
API is mostly opaque `VALUE` + function calls, so ~200 lines of hand-picked
`extern(C)` declarations replace the old 2,400-line bcd.gen blob. Struct
accesses (`RSTRING(str).ptr`) are gone — everything goes through exported
functions (`rb_string_value_ptr`, `rb_float_value`, `rb_ary_entry`, ...).

## Requirements

- Ruby 4.0 (any install with `libruby` and headers)
- GDC ≥ 13 (tested: gdc-14 14.2.0, D front-end 2.10x)
- GNU make

## Build & test

```sh
make        # builds .build/dextest.so
make test   # runs test/run.rb against the built extension
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

MIT (as the original).
