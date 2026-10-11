#!/usr/bin/env ruby
# Acceptance suite for the missing-API bindings (dexitest).
# Exercises: rb_yield, rb_block_given_p, rb_yield_values2, rb_block_call,
# rb_rescue, rb_ensure, rb_define_singleton_method, rb_scan_args,
# rb_thread_call_without_gvl, variadic def! (D default args -> optional).

require "pathname"
EXT = Pathname.new(__dir__).parent + ".build" + "dexitest.so"
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

# ---------------------------------------------------------------- rb_yield
assert_equal(55, DExitTest.sum_to(10) { |i| i }, "rb_yield: sum 1..10 via block")
assert_equal(110, DExitTest.sum_to(10) { |i| i * 2 }, "rb_yield: block sees each value")

# ------------------------------------------- rb_block_given_p / yield_values2
assert_equal(-1, DExitTest.pair_sums(5), "rb_block_given_p: no block -> -1")
assert_equal(165, DExitTest.pair_sums(5) { |a, b| a + b },
             "rb_yield_values2: |a, b| pairs (1,10)..(5,50) summed")
assert_equal(3850, DExitTest.pair_sums(10) { |a, b| a * b },
             "rb_yield_values2: products summed")

# ---------------------------------------------------------------- rb_block_call
assert_equal([1, 2, 3], DExitTest.block_collect([1, 2, 3]),
             "rb_block_call: C-implemented block collects each entry")
assert_equal(%w[a b c], DExitTest.block_collect(["a", "b", "c"]),
             "rb_block_call: works on any enumerable responding to each")
assert_equal([], DExitTest.block_collect([]), "rb_block_call: empty array")

# ---------------------------------------------------------------- rb_rescue
assert_equal("rescued", DExitTest.div_rescue(1, 0), "rb_rescue: ZeroDivisionError -> handler")
assert_equal("rescued", DExitTest.div_rescue(1, 0) { |e| "not called" },
             "rb_rescue: handler result returned, block irrelevant")
assert_equal(42, DExitTest.safe_rescue, "rb_rescue: success path returns b_proc value")

# ---------------------------------------------------------------- rb_ensure
assert_equal(true, DExitTest.ensure_success, "rb_ensure: ensure ran after success")
assert_raises(RuntimeError) { DExitTest.ensure_raises }
assert(DExitTest.ensure_raised_flag != 0 && DExitTest.ensure_raised_flag != false,
       "rb_ensure: ensure ran despite raise (got #{DExitTest.ensure_raised_flag.inspect})")

# ------------------------------------------------- rb_define_singleton_method
obj = Object.new
DExitTest.make_singleton(obj)
assert_equal("hi from singleton", obj.dexitest_greet,
             "rb_define_singleton_method: per-object method")
assert_raises(NoMethodError) { Object.new.dexitest_greet }

# ---------------------------------------------------------------- rb_scan_args
n, a, b, rest = DExitTest.scan(1)
assert_equal([1, 1, nil, []], [n, a, b, rest], 'rb_scan_args "11*": 1 mandatory')
n, a, b, rest = DExitTest.scan(1, 2)
assert_equal([2, 1, 2, []], [n, a, b, rest], 'rb_scan_args "11*": 1 mandatory + 1 optional')
n, a, b, rest = DExitTest.scan(1, 2, 3, 4)
assert_equal([4, 1, 2, [3, 4]], [n, a, b, rest], 'rb_scan_args "11*": splat rest')

# ---------------------------------------------------------------- GVL
r = DExitTest.nogvl
assert(r.is_a?(Integer) && r >= 0, "rb_thread_call_without_gvl: D nap returned")

# prove another Ruby thread ran while the GVL was released
main_result = Queue.new
t = Thread.new { main_result << DExitTest.nogvl_parallel }
sleep 0.01
DExitTest.tick                       # runs while the D nap holds no GVL
t.join
assert_equal(1, main_result.pop, "rb_thread_call_without_gvl: D nap + parallel Ruby thread OK")

# ---------------------------------------------------------------- variadic def!
assert_equal(33, DExitTest.var_sum(1), "variadic def!: a=1, defaults b=2 c=30")
assert_equal(33, DExitTest.var_sum(1, 2), "variadic def!: a=1 b=2, default c=30")
assert_equal(3, DExitTest.var_sum(1, 2, 0), "variadic def!: all three explicit")
assert_raises(ArgumentError) { DExitTest.var_sum }
assert_raises(ArgumentError) { DExitTest.var_sum(1, 2, 3, 4) }

assert_equal("hello, world!", DExitTest.var_greet("world"), "variadic def!: string defaults")
assert_equal("howdy, world?", DExitTest.var_greet("world", "howdy", "?"),
             "variadic def!: all explicit")

assert_equal(10, DExitTest.var_raw(10), "variadic def!: raw VALUE passthrough, 1 arg")
assert_equal("abc", DExitTest.var_raw("abc"), "variadic def!: raw VALUE passthrough, string")
assert_equal(20, DExitTest.var_raw(10, 2), "variadic def!: raw VALUE + explicit optional arg")

puts
if $failures.zero?
  puts "PASS: all #{$count} assertions green"
  exit 0
else
  puts "FAIL: #{$failures}/#{$count} assertions failed"
  exit 1
end