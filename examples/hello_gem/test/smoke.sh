#!/usr/bin/env bash
# smoke.sh — build the hello_gem extension from D sources and assert it works.
#
# One-shot end-to-end check for the packaging example:
#   extconf.rb -> make -> require -> exercise def! functions + the wrapped
#   struct's object protocol. Exits non-zero on the first failed assertion.
#
# Usage: bash test/smoke.sh [ruby-binary]      (default: the rudy4 asdf ruby)

set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
RUBY="${1:-$HOME/.asdf/installs/ruby/4.0.7/bin/ruby}"
GDC="${GDC:-gdc-14}"

echo "== ruby: $($RUBY -v)"
echo "== gdc:  $($GDC --version | head -1)"

cd "$HERE/ext/hello_gem"
rm -f hello_gem_ext.so
GDC="$GDC" "$RUBY" extconf.rb
make
make install RUBYARCHDIR="$HERE/lib"

echo "== running smoke assertions"
cd "$HERE"
"$RUBY" -Ilib - <<'RUBY'
require "hello_gem"

checks = 0
assert = lambda do |cond, msg|
  checks += 1
  raise "FAIL: #{msg}" unless cond
end

# def! global functions + automatic conversion
assert.(greet("world") == "hello, world!", "greet/string conversion")
assert.(add(2, 3) == 5, "add/long conversion")
assert.(is_even(4) == true, "is_even true")
assert.(is_even(5) == false, "is_even false")
assert.(describe("cat", 3) == "cat x3", "multi-arg conversion")

# namespaced module function
assert.(HelloGem.module_greet("D") == "hello, D!", "module function")

# wrapped D struct: allocate + initialize
v = HelloVec2.new(3.0, 4.0)
assert.(v[0] == 3.0 && v[1] == 4.0, "component get")
assert.(v.norm2 == 25.0, "norm2")

# object protocol
assert.(v == HelloVec2.new(3.0, 4.0), "value equality")
assert.(v.eql?(HelloVec2.new(3.0, 4.0)), "eql?")
assert.(v.hash == HelloVec2.new(3.0, 4.0).hash, "hash contract")
assert.(v.dup[0] == 3.0, "dup copies struct")
assert.(v.inspect.include?("x=3"), "inspect via hook")
h = { HelloVec2.new(1.0, 1.0) => :found }
assert.(h[HelloVec2.new(1.0, 1.0)] == :found, "hash keying")

# freeze enforcement (rb_check_frozen in the mutator)
f = HelloVec2.new(1.0, 2.0)
f.freeze
begin
  f[0] = 9.0
  raise "FAIL: frozen mutator did not raise"
rescue FrozenError
  checks += 1
end

# mutating a copy does not touch the original
a = HelloVec2.new(1.0, 1.0)
b = a.dup
b[0] = 7.0
assert.(a[0] == 1.0 && b[0] == 7.0, "dup independence")

# pure-Ruby convenience on top of the native struct
u = HelloGem.unit(0.0, 5.0)
assert.((u.norm2 - 1.0).abs < 1e-9, "HelloGem.unit")

puts "hello_gem smoke: #{checks} assertions OK"
RUBY
