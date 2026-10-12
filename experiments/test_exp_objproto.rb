#!/usr/bin/env ruby
# Object-protocol torture suite for the RudyObjectProtocol mixin (backlog item 6).
# allocate / dup / clone / == / eql? / hash / inspect / freeze on a protocol'd
# D-struct class (DRudyVec over Vec2) — plus Hash keying and GC-storm survival.
# Findings so far: none yet (first run of this suite).

require "pathname"
EXT = Pathname.new(__dir__).parent + ".build" + "exp_objproto.so"
raise "extension not built: run `make exp-test EXP=exp_objproto` first" unless EXT.exist?
require EXT.to_s

$failures = 0
$count = 0

def assert(cond, msg)
  $count += 1
  if cond then puts "ok #{$count} - #{msg}"
  else $failures += 1; puts "FAIL #{$count} - #{msg}" end
end

def assert_equal(expected, actual, msg = nil)
  assert(expected == actual, "#{msg || 'equal'}: expected #{expected.inspect}, got #{actual.inspect}")
end

def assert_raises(exp)
  yield
  assert(false, "expected #{exp} to be raised")
rescue exp
  assert(true, "raised #{exp}")
end

# ---------------------------------------------------------------- allocate

assert_equal("DRudyVec", DRudyVec.new(1.0, 2.0).class.name, "allocate: class wired")

a = DRudyVec.new(1.0, 2.0)
assert_equal(1.0, a[0], "initialize sets x")
assert_equal(2.0, a[1], "initialize sets y")
assert_equal(0.0, a[2], "zalloc zeroed the padding field (extra)")

assert_raises(TypeError) { DRudyVec.new("x", 1.0) }
assert_raises(TypeError) { DRudyVec.new(1.0, :y) }

# ---------------------------------------------------------------- inspect

assert_equal("#<DRudyVec: x=1 y=2>", a.inspect, "inspect format via hook")
assert(a.to_s.start_with?("#<DRudyVec:0x"), "default to_s is Object#to_s (NOT delegated to inspect; matches Ruby)")
assert(a.to_s.match?(/\A#<DRudyVec:0x[0-9a-f]+>\z/), "to_s has the default Kernel#to_s shape")

# ---------------------------------------------------------------- ==/eql?/hash

b = DRudyVec.new(1.0, 2.0)
c = DRudyVec.new(3.0, 4.0)

assert(a == b, "== true for byte-equal structs")
assert(!(a == c), "== false for different structs")
assert(a.eql?(b), "eql? true for byte-equal structs")
assert(!(a.eql?(c)), "eql? false for different structs")
assert(!(a == Object.new), "== vs non-wrapper is false, no crash")

# NaN self-equality: memcmp says equal bits => ==. (Not IEEE ==; documented.)
nan1 = DRudyVec.new(Float::NAN, 1.0)
nan2 = DRudyVec.new(Float::NAN, 1.0)
assert(nan1 == nan2, "memcmp == treats NaN-pairs as equal (bit equality)")

assert_equal(b.hash, a.hash, "hash equal for memcmp-equal structs")
assert(a.hash != c.hash, "hash differs for different structs (FNV-1a)")
assert(a.hash.is_a?(Integer) && a.hash >= 0, "hash is non-negative Integer (sign masked)")

# ---------------------------------------------------------------- dup/clone

d = a.dup
assert_equal(a[0], d[0], "dup copies x")
assert_equal(a[1], d[1], "dup copies y")
d[0] = 9.0
assert_equal(1.0, a[0], "dup is deep-enough: mutating copy does not touch orig")

e = a.clone
assert_equal(a[0], e[0], "clone copies x")
assert_equal(a.frozen?, e.frozen?, "clone preserves frozen state")

f = a.dup.freeze
g = f.dup
assert(!g.frozen?, "dup of frozen is NOT frozen (matches Kernel#dup semantics)")
assert_equal(1.0, g[0], "dup of frozen is a readable copy")
g[0] = 7.0
assert_equal(7.0, g[0], "unfrozen dup is mutable")
assert_equal(1.0, f[0], "original frozen object untouched")
h = f.clone
assert(h.frozen?, "clone of frozen IS frozen (matches Kernel#clone semantics)")

assert_raises(RuntimeError) { f[0] = 5.0 }
assert_equal(1.0, f[0], "frozen object unchanged by rejected mutation")

assert_equal("#<DRudyVec: x=1 y=2>", a.inspect, "orig a inspects with x=1 (dup deep-enough)")
assert_equal("#<DRudyVec: x=9 y=2>", d.inspect, "mutated dup inspects with x=9 (correct: mutation happened earlier)")

# ---------------------------------------------------------------- Hash keying

# NOTE: a and b are memcmp-equal (both (1,2)), so h[b]= below legitimately
# REPLACES h[a]'s value — use hh (fresh Hash) to encode that as a finding.
hh = {}
hh[a] = :a
hh[b] = :b2
assert_equal(:b2, hh[a], "byte-equal key replaced: fetch returns latest value")
assert_equal(1, hh.size, "equal keys collide into one entry")

h = {}
h[a] = :a
h[c] = :c
assert_equal(:a, h[b], "byte-equal struct found as Hash key")
assert_equal(:c, h[c], "distinct struct found as Hash key")
assert_equal(2, h.size, "two distinct keys -> two entries")
h[b] = :b2
assert_equal(:b2, h[a], "re-assign over equal key replaces value")
assert_equal(2, h.size, "re-assign over equal key does not grow Hash")

# ---------------------------------------------------------------- norm2 read path

assert((a.norm2 - 5.0).abs < 1e-9, "norm2 computes through unwrap")

# ---------------------------------------------------------------- GC storm

100.times do |i|
  w = DRudyVec.new(i.to_f, (i + 1).to_f)
  w.dup
  w.clone
end
GC.start
assert_equal(2, h.size, "Hash survives Ruby GC.start")
assert_equal(:b2, h[b], "keys still resolve after GC.start (byte-equal key stored b2)")

GC.start(full_mark: true, immediate_sweep: true)
assert_equal("#<DRudyVec: x=1 y=2>", a.inspect, "long-lived wrapper sane after full GC")

# ---------------------------------------------------------------- done

puts
if $failures.zero?
  puts "PASS: all #{$count} assertions green"
  exit 0
else
  puts "FAIL: #{$failures}/#{$count} assertions failed"
  exit 1
end
