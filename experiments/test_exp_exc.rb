#!/usr/bin/env ruby
# EXPERIMENT 6 — D <-> Ruby exception ping-pong torture.
#
# Ruby-side stepper methods used by the D code (called via rb_funcall on
# Kernel): the D code calls Ruby, which calls D back — mutual recursion
# through the boundary with raises at the bottom.
#
# Assertions:
#   1. rb_rescue: rescue callback runs with the exception, returns marker
#   2. rb_ensure: ensure runs despite the raise, exception propagates
#   3. nested rb_protect: inner catch contained, outer sees clean state
#   4. deep ping-pong: 50-level mutual recursion D<->Ruby, raise at the
#      bottom, rescue at top — max_depth bookkeeping survives the unwind
#   5. exception identity: the VALUE raised inside the protected body is
#      the SAME object Ruby rescues (rb_exc_raise re-raise path)
#   6. state intact after every unwind: counters monotonic, no drift

require "pathname"
EXT = Pathname.new(__dir__).parent + ".build" + "exp_exc.so"
raise "exp_exc not built: run `make exp` first" unless EXT.exist?
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
  nil
rescue exp => e
  assert(true, "raised #{exp}")
  e
rescue => e
  assert(false, "expected #{exp}, got #{e.class}: #{e.message}")
  e
end

# ---------------------------------------------------------------- steppers
# The D code calls these on Kernel; they call straight back into D.
# (defined on Object so both Kernel funcall and plain calls find them)

def DExc_ping_pong(depth)
  DExc.echo_or_raise(depth)
end

def DExc_deep_ping_pong(depth)
  DExc.deep_ping_pong(depth)
end

def DExc_raise
  raise "ruby side raised"
end

def DExc_inner
  DExc.protect_inner           # nested rb_protect, contained at the inner level
end

# ---------------------------------------------------------------- round 1: rb_rescue
calls0 = DExc.calls
assert_equal("rescued", DExc.rescue_case, "rb_rescue rescue callback's return value surfaced")
assert_equal(1, DExc.rescues, "rescue callback ran exactly once")
assert(DExc.exc_kept.is_a?(RuntimeError), "rescue callback received the exception VALUE")
assert(DExc.exc_kept.message.include?("ruby side raised"),
       "exception message crossed the boundary intact: #{DExc.exc_kept.message.inspect}")
assert(DExc.calls > calls0, "D-side call counter advanced")

# ---------------------------------------------------------------- round 2: rb_ensure
ensures0 = DExc.ensures
e = assert_raises(RuntimeError) { DExc.ensure_case }
assert_equal(ensures0 + 1, DExc.ensures, "ensure callback ran despite the raise")
assert(e.message.include?("ruby side raised"), "original exception propagated through rb_ensure")

# ---------------------------------------------------------------- round 3: nested protect
assert_equal("inner caught", DExc.protect_case,
             "inner rb_protect caught the raise; outer protect saw clean state")
assert_equal(1, DExc.protects, "exactly one protect observed a raise (the inner one)")

# ---------------------------------------------------------------- round 4: deep ping-pong
# 50 levels of D -> Ruby -> D mutual recursion, RuntimeError at the bottom,
# rescued at the top level. All D frames longjmp-skipped.
max0 = DExc.max_depth
e = assert_raises(RuntimeError) { DExc.deep_ping_pong(50) }
assert(e.message.include?("deep bottom"), "raise came from the deepest D frame")
assert(DExc.max_depth >= 50, "recursion actually descended (max_depth #{DExc.max_depth}, was #{max0})")
assert_equal(false, DExc.ping_pong_failed, "ping-pong bookkeeping clean after unwind")

# ---------------------------------------------------------------- round 5: identity
kept = DExc.identical_exc
assert(kept.is_a?(RuntimeError), "identical_exc returned the exception object itself")
same = false
begin
  DExc.reraise(kept)             # rb_exc_raise of the SAME VALUE
rescue RuntimeError => again
  same = again.equal?(kept)
end
assert(same, "re-raised exception is the SAME object (rb_exc_raise identity)")
assert(DExc.exc_reseen.equal?(kept), "D saw the same VALUE both times (obj identity stable)")

# ---------------------------------------------------------------- round 6: state intact
# After all unwinds the counters are consistent and a fresh rescue works.
before = [DExc.calls, DExc.rescues, DExc.ensures, DExc.protects]
assert_equal("rescued", DExc.rescue_case, "fresh rescue works after all the unwinding")
after = [DExc.calls, DExc.rescues, DExc.ensures, DExc.protects]
assert_equal([before[0] + 1, before[1] + 1, before[2], before[3]], after,
             "counters advanced by exactly the expected amounts (state intact)")

if $failures == 0
  puts "\nEXP EXC PASS: all #{$count} assertions green"
else
  puts "\nEXP EXC FAIL: #{$failures}/#{$count} assertions failed"
  exit 1
end
