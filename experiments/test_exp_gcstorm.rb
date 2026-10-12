#!/usr/bin/env ruby
# EXPERIMENT 5 — TypedData allocation/free storm under GC pressure.
#
# Ruby threads hammer DExpStorm.make(n) (n malloc'd TypedData wrappers each,
# dropped immediately for Ruby GC to collect) while a D background thread
# churns D-GC memory and forces D collections. At the end:
#   alloc_count == freed + live (balance check, no double-free / leak)
#   churn_cycles > 0 (the D thread really ran concurrently)

require "pathname"
EXT = Pathname.new(__dir__).parent + ENV.fetch("RUDY_BUILD_DIR", ".build") + "exp_gcstorm.so"
raise "exp_gcstorm not built: run `make exp` first" unless EXT.exist?
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

# ---------------------------------------------------------------- sanity
assert_equal(0, DExpStorm.balance, "balance starts at 0 (no wrappers yet)")

# single-thread smoke: 100 wrappers, GC, then all should free
DExpStorm.make(100)
GC.start
sleep 0.1
GC.start
assert_equal(100, DExpStorm.alloc_count, "alloc_count after smoke round")
assert_equal(100, DExpStorm.free_count, "all 100 smoke wrappers freed after GC.start")
assert_equal(0, DExpStorm.balance, "balance back to 0 after smoke round")

# ---------------------------------------------------------------- storm
DExpStorm.start_churn
assert_equal(true, DExpStorm.start_churn == false, "second start_churn is a no-op (false)")

threads = 8.times.map do
  Thread.new do
    30.times do
      DExpStorm.make(200)
      GC.start
    end
  end
end
threads.each(&:join)

churn_cycles_mid = DExpStorm.churn_cycles
DExpStorm.stop_churn

assert(DExpStorm.churn_cycles > 0, "D churn thread ran (#{DExpStorm.churn_cycles} cycles)")
assert_equal(100 + 8 * 30 * 200, DExpStorm.alloc_count,
             "alloc_count exact: 100 smoke + 8 threads * 30 rounds * 200")

# every wrapper must be freed exactly once after full GC
20.times { GC.start; sleep 0.05 }
assert_equal(DExpStorm.alloc_count, DExpStorm.free_count,
             "free_count == alloc_count (every wrapper freed exactly once)")
assert_equal(0, DExpStorm.balance, "final balance 0: no leak, no double free")

if $failures == 0
  puts "\nEXP GCSTORM PASS: all #{$count} assertions green"
else
  puts "\nEXP GCSTORM FAIL: #{$failures}/#{$count} assertions failed"
  exit 1
end
