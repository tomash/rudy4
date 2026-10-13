# Changelog

All notable changes to this project are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-10-13

### Added

- **The `rudy4` gem** (`rudy4.gemspec`, `lib/rudy4/`, `bin/rudy4`) — packages
  rudy4 as a command, not a repo to clone. The gem ships the D library under
  `vendor/rudy/` so a generated project builds with no rudy4 checkout and no
  `RUDY4_ROOT`.
  - `rudy4 init NAME` scaffolds a self-contained extension gem (gemspec,
    `lib/`, `ext/NAME/` with the *vendored* `rudy/` sources, `Rakefile`,
    `test/`) and prints the compile/test next steps.
  - `rudy4 doctor` verifies the Ruby toolchain, headers, shared libruby and
    GDC — then proves the setup by scaffolding and compiling a throwaway
    extension, so failures name the missing piece. Untested Ruby majors and
    pre-13 GDC are warnings, not refusals.
  - `rudy4 vendor` re-copies the D library into an existing project after a
    gem upgrade (`src/rudy/` stays the source of truth).
- `scripts/vendor_sync.sh` / `scripts/vendor_check.sh` — keep `vendor/rudy/`
  in step with `src/rudy/`; CI fails on drift.
- `test/rudy4_test.rb` — the gem's suite (136 assertions: scaffold contents,
  argument validation, `--force`, vendor refresh, doctor
  pass/fail). `RUDY4_FULL=1` additionally scaffolds a project and drives
  `rake test` inside it with GDC (143 assertions, `make gem-test-full`).
- `make gem-test` / `gem-test-full` / `vendor` / `vendor-check` / `gem-build`.

### Fixed

- The scaffolded template no longer demonstrates array *parameters*
  (`double[] xs`) — `d_type` has no array/AA decode path, so that template
  would have failed to compile. The generated D file now uses the paths that
  are actually supported: D default values for optional arguments, `Rest` for
  Ruby `*args`, and a dynamic-array *return* (`double[] squares(long n)`),
  alongside `long`/`string`/`bool`.

## [0.1.1] - 2026-10-13

### Added

- **`exp_nonregression`** (`experiments/exp_nonregression.d` +
  `test_exp_nonregression.rb`, 20 assertions) — evidence for the three
  documented non-goals: Fiber switches through D frames, Ractor
  non-shareability (asserted VM refusal), and interruptibility of a long
  GVL-held D call vs the GVL-released variant. Findings #25–#27 in
  `experiments/NOTES.md`.
- **README "Known limitations (non-goals)"** section and a matching
  `experiments/NOTES.md` section, so the boundaries are stated up front
  instead of being discoverable only by reading the experiment notes.

## [0.1.0] - 2026-10-13

First tagged release: rudy4 revival targeting Ruby 4.0 and GDC 14.

### Added

- **`def!`** — register a D function as a Ruby method with automatic
  argument conversion (`src/rudy/defs.d`, `src/rudy/convert.d`).
  - Variadic `def!` with D default arguments → Ruby optional arguments.
  - Blocks (`RubyBlock`), `*rest` (`Rest`), `**kwargs` (`KwArgs`),
    `Self` receiver, `def_private!` / `def_protected!` /
    `def_singleton!` / `def_singleton_on!`.
- **`RudyTypedData`** (`src/rudy/typeddata.d`) — wrap D structs as Ruby
  objects, with GC mark + compaction callbacks (`rb_gc_mark_movable` /
  `rb_gc_location`).
- **`RudyObjectProtocol`** (`src/rudy/objproto.d`) — companion mixin for
  wrapped structs: `allocate`, `initialize_copy` (dup/clone, frozen
  propagation), `==`/`eql?`/`hash`, `inspect`, and mutator freeze guards.
- **Hand-written Ruby 4.0 C-API binding** (`src/rudy/bind/value.d`),
  ~220 lines: value/type checks, strings, arrays, hashes, symbols, blocks,
  structured exceptions (`rb_rescue`/`rb_ensure`/`rb_protect`), per-object
  methods, GVL release (`rb_thread_call_without_gvl`).
- **`examples/hello_gem/`** — a complete gem-shaped extension showing how to
  actually ship a D-backed gem: `*.gemspec`, `ext/<name>/extconf.rb`,
  `lib/`, and packaging/installation instructions.
- **Experiments** (`experiments/`) — ten torture suites / 432 assertions:
  wrap, cross, perf, http, gcstorm, exc, compact, convert, defargs,
  objproto. Their findings are catalogued in `experiments/NOTES.md`
  (24 findings).
- **CI** (`.github/workflows/ci.yml`) — GitHub Actions on ubuntu-24.04:
  gdc-14 + Ruby 4.0.7 built from source (`--enable-shared`), runs
  `make test`, `make exp-test`, and the ABI audit.
- **ABI conformance audit** (`scripts/abi_audit.sh`) — `nm -D libruby` vs
  the `extern(C)` declarations in `src/rudy/bind/value.d`; 137 bound
  symbols, 0 misbinds.
- **Memory-safety runs** (`make memcheck`, `scripts/memcheck.sh`) —
  AddressSanitizer subset of the experiment suites (`.build.asan/`, driven
  by `RUDY_BUILD_DIR`). Two hard gdc-14 limitations documented
  (`experiments/NOTES.md` #23/#24).
- **LICENSE** (MIT) and this changelog.

### Known limitations

See `experiments/NOTES.md` for the full catalogue. Highlights:

- gdc-14 AddressSanitizer SEGVs on any explicit druntime `rt_init()` (#23);
  only the `rt_init`-free experiments run under ASan.
- `exp_http` aborts under ASan with `Failed to munmap` (#24) — built but not
  run.
- GDC 14 rejects `&fn` as a template value argument in hook positions —
  pass hooks as ALIAS parameters with bare symbol names (#22).
- Forking after a D-runtime-initialized `.so` is loaded is unsafe — use a
  subprocess re-exec for crash-witness tests.

[Unreleased]: https://github.com/tomash/rudy4/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/tomash/rudy4/releases/tag/v0.2.0
[0.1.1]: https://github.com/tomash/rudy4/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/tomash/rudy4/releases/tag/v0.1.0
