# hello_gem — a shippable D-backed Ruby extension

The rest of the rudy4 repo is *acceptance-test shaped*: `src/dextest.d` and
everything under `experiments/` exists to exercise the library, not to be
installed. This directory is the counter-example — a real gem layout you can
`gem build` / `gem install`, whose native half is written in **D** and
compiled with **GDC**.

```
hello_gem/
  hello_gem.gemspec        gem metadata; declares the extconf.rb extension
  lib/hello_gem.rb         pure-Ruby half: loads the .so, adds conveniences
  lib/hello_gem/version.rb
  ext/hello_gem/hello_gem.d    the native extension (def! + wrapped struct)
  ext/hello_gem/extconf.rb     writes a Makefile that drives gdc
  test/smoke.sh                one-shot build + assert script
```

## What the native half shows

`ext/hello_gem/hello_gem.d` uses the whole rudy4 surface in one file:

| Ruby-side        | D-side                                     |
|------------------|--------------------------------------------|
| `greet(name)`    | `def!(greet)` with automatic string conversion |
| `add(a, b)`      | `def!(add)` with `long` conversion         |
| `is_even(n)`     | `def!(is_even)` → D `bool` → Ruby `true/false` |
| `HelloGem.module_greet` | `def!("HelloGem", greet, ...)` namespaced |
| `HelloVec2#[]`, `#[]=`, `#norm2` | `RudyTypedData!(Vec2)` + raw `extern(C)` |
| `HelloVec2#dup/#clone/#==/#hash/#inspect` | `RudyObjectProtocol!(Vec2)` |
| `vec.freeze` guards `vec[0] = …` | `rb_check_frozen(self)` in the mutator |

## Building and running

From this directory:

```sh
# 1. compile the extension in place (leaves hello_gem_ext.so in lib/)
cd ext/hello_gem
ruby extconf.rb
make
make install RUBYARCHDIR=../../lib      # or let it default

# 2. try it
cd ../..
ruby -Ilib -e 'require "hello_gem"; p greet("world"); v = HelloVec2.new(3, 4); p v.norm2; p v == v.dup'
```

Then the gem itself:

```sh
gem build hello_gem.gemspec
gem install hello_gem-0.1.0.gem
ruby -e 'require "hello_gem"; p add(2, 3)'
```

`test/smoke.sh` does the build-and-assert loop in one shot (17 assertions).

### Installing outside the repo

`gem build` / `gem install` compiles the extension in a temporary copy of
the gem, so the `../../../src/rudy` auto-detection no longer applies. When
installing from an unpacked gem (not from this checkout), point `RUDY4_ROOT`
at a rudy4 checkout:

```sh
RUDY4_ROOT=/path/to/rudy4 GDC=gdc-14 gem install ./hello_gem-0.1.0.gem
```

A published gem would instead vendor `src/rudy` inside the gem (or depend on
a `rudy4` gem that ships it), removing the need for `RUDY4_ROOT` entirely.

## Requirements

- Ruby 4.0 (the suite targets the 4.0 C API),
- GDC 14 (`gdc-14`),
- the rudy4 library sources, found at `../../../src/rudy` (this checkout) or
  wherever `$RUDY4_ROOT` points.

## How the extconf.rb trick works

RubyGems' native-extension protocol is language-agnostic: it runs your
`extconf.rb`, expects it to emit a `Makefile` with `all` and `install`
targets, then runs them. `extconf.rb` here interrogates `RbConfig` for the
Ruby header dirs and `libruby` exactly like `mkmf` would, then emits a
Makefile whose `CC` is `gdc-14` and that compiles the `.d` sources alongside
`hello_gem.d`. Ruby never learns the language was D.

A gem published like this would vendor the rudy4 `src/rudy` tree into the
gem (or depend on a `rudy4` gem that ships it); the in-repo default just
walks four directories up to this checkout.
