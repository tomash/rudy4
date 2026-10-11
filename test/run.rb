#!/usr/bin/env ruby
# Acceptance suite for rudy-d's dextest extension (dexter revival, 2010 -> 2026).

require_relative "dextest_loader"

$failures = 0
$count = 0

def assert(cond, msg)
  $count += 1
  if cond
    puts "ok #{$count} - #{msg}"
  else
    $failures += 1
    puts "FAIL #{$count} - #{msg}"
  end
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
  assert(false, "expected #{exp}, got #{e.class}")
end

# ---------------------------------------------------------------- raw C API class
d = DexterClass.new
assert_equal(Class, DexterClass.class, "DexterClass is a class")
assert_equal(Object, DexterClass.superclass, "DexterClass < Object")
assert_equal(10, d.return_ten, "return_ten")
assert_equal([], d.arr, "arr starts empty")
d.add(1); d.add(2)
assert_equal([1, 2], d.arr, "add pushes raw VALUEs")
d.native_add(22)
assert_equal([1, 2, 23], d.arr, "native_add converts via num2long/ll2inum")
d.add_strings_first_letter("showtime!")
assert_equal([1, 2, 23, "s"], d.arr, "add_strings_first_letter")

# ---------------------------------------------------------------- def! globals
assert_equal(15, the_new_fifteen, "def! global function")
assert_equal(33, convert_integer_two_ways(33), "def! integer round trip")
assert_equal(45.67, convert_float_two_ways(45.67), "def! float round trip")
assert_equal("somestring", convert_string_two_ways("somestring"), "def! string round trip")
assert_equal(true, convert_bool_two_ways(true), "def! bool true round trip")
assert_equal(false, convert_bool_two_ways(false), "def! bool false round trip")
assert_equal(17, add_five(12), "def! computed int")
assert_equal("hi tomash 42", DexterModule.greet("tomash", 42), "def! module function, 2 args, mixed types")

# ---------------------------------------------------------------- arity / errors
assert_raises(ArgumentError) { convert_integer_two_ways }        # wrong arity
assert_raises(TypeError) { convert_integer_two_ways("nope") }    # bad conversion

# ---------------------------------------------------------------- results
puts
if $failures.zero?
  puts "PASS: all #{$count} assertions green"
  exit 0
else
  puts "FAIL: #{$failures}/#{$count} assertions failed"
  exit 1
end
