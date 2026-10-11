#!/usr/bin/env ruby
# Acceptance suite for the typed-data extension (rudy/typeddata.d).
# Exercises: wrap/unwrap via TypedData API (rb_data_typed_object_wrap /
# rb_check_typeddata), alloc func, det, GC stress, TypeError on bad unwrap.

require "pathname"
EXT = Pathname.new(__dir__).parent + ".build" + "dtypetest.so"
raise "extension not built: run `make` first" unless EXT.exist?
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
rescue => e
  assert(false, "expected #{exp}, got #{e.class}: #{e.message}")
end

# ---------------------------------------------------------------- basics
m = DTypeMatrix.new(3, 3)
assert_equal(9, DTypeMatrix.allocate.unwrap_other(m), "typed wrap/unwrap round trip")
[[2, 0, 1], [0, 3, 0], [1, 0, 2]].each_with_index do |row, r|
  row.each_with_index { |v, c| m[r, c] = v }
end
assert_equal([[2, 0, 1], [0, 3, 0], [1, 0, 2]], m.to_a, "to_a returns matrix contents")
assert((m.det - 9.0).abs < 1e-9, "3x3 det == 9.0 (Laplace, recursion)")
assert_equal(24, DTypeTest::SIZEOF, "sizeof Matrix struct exposed (2*8 + 8 == 24 on LP64)")

# 10x10 identity perturbation — deep det recursion
big = DTypeMatrix.new(10, 10)
10.times { |r| 10.times { |c| big[r, c] = (r == c) ? 1.0 : 0.0 } }
big[3, 3] = 3.5
big[7, 0] = 2.0
assert((big.det - 3.5).abs < 1e-9, "10x10 identity det with [3,3]=3.5")

# ---------------------------------------------------------------- TypeError
assert_raises(TypeError) { DTypeMatrix.allocate.unwrap_other("not a matrix") }
assert_raises(TypeError) { DTypeMatrix.allocate.unwrap_other(42) }
assert_raises(TypeError) { DTypeMatrix.allocate.unwrap_other(DTypeMatrix) }

# ---------------------------------------------------------------- GC stress
before = `ps -o rss= -p #{Process.pid}`.to_i
m2 = DTypeMatrix.new(4, 4)
m2.stress(100_000)
after = `ps -o rss= -p #{Process.pid}`.to_i
assert(after - before < 50_000, "100k typed wrap/free cycles: RSS delta #{after - before} KB < 50 MB")

puts
if $failures.zero?
  puts "PASS: all #{$count} assertions green"
  exit 0
else
  puts "FAIL: #{$failures}/#{$count} assertions failed"
  exit 1
end