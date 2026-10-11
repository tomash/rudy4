#!/usr/bin/env ruby
# EXPERIMENT 7 — GC compaction vs wrapped structs and registered globals.
#
# Finding #11 (library bug, FIXED in this PR): a wrapped D struct that
# holds live VALUEs with no dmark callback in its descriptor lets Ruby's
# GC collect the referents while the wrapper object is still alive.
# Observed as: read_box on a surviving DBox returns a Module / an
# unrelated String — the freed VALUE slots got reused by other objects.
#
# Part A (registered globals): VALUEs in D-side globals registered via
#   rb_gc_register_address survive GC+compaction; rb_gc_location refresh
#   returns the (possibly moved) referent.
# Part B (guarded box): DGuardedBox (dmark=rb_gc_mark_movable +
#   dcompact=rb_gc_location rewrite) keeps referents alive and identical
#   across full GCs, compactions, and heavy churn.
# Part C (unguarded box, negative control): DBox (no callbacks) corrupts
#   — reported as diagnostics; corruption is GC-scheduling dependent in
#   principle, but reliably reproduced here.

require "pathname"
EXT = Pathname.new(__dir__).parent + ".build" + "exp_compact.so"
raise "exp_compact not built: run `make exp` first" unless EXT.exist?
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

def churn
  3000.times.map { |i| "f-#{i}-#{"y" * (i % 200)}" }
  2000.times.map { |i| [i, i + 1, "a#{i}"] }
end

def alive?(id)
  ObjectSpace._id2ref(id)
  true
rescue RangeError
  false
end

def make_unguarded
  str = "U-#{rand(1e12)}"
  arr = [1, 2, 3, str]
  box = DExpCompact.make_box(str, arr)      # no dmark (control)
  [box, str.object_id, arr.object_id]
end

def make_guarded
  str = "G-#{rand(1e12)}"
  arr = [4, 5, 6, str]
  box = DExpCompact.make_gbox(str, arr)     # dmark + dcompact
  [box, str.object_id, arr.object_id]
end

# ---------------------------------------------------------------- part A

id = DExpCompact.stash("stashed before compaction")
churn; GC.start; GC.compact; GC.start

peeked = DExpCompact.peek_stashed(id)
assert(!peeked.nil?, "A1: stashed object survives compaction (rb_gc_register_address roots it)")
assert_equal("stashed before compaction", peeked.to_s, "A2: stashed string readable after GC.compact")

refreshed = DExpCompact.refresh(id)
assert_equal("stashed before compaction", refreshed.to_s,
             "A3: rb_gc_location refresh returns the (possibly moved) referent")

# ---------------------------------------------------------------- part B

gbox, gstr_id, garr_id = make_guarded

GC.start; GC.compact; GC.start
churn
GC.start; GC.compact; GC.start
churn
GC.start; GC.compact; GC.start

assert(alive?(gstr_id), "B1: guarded-box string referent alive after GC+compact (dmark works)")
assert(alive?(garr_id), "B2: guarded-box array referent alive after GC+compact (dmark works)")

g = DExpCompact.read_box(gbox)
assert(g[0].is_a?(String) && g[0].start_with?("G-"),
       "B3: guarded box string intact (not a reused slot)")
assert(g[1].is_a?(Array) && g[1][0, 3] == [4, 5, 6],
       "B4: guarded box array intact (not a reused slot)")
assert(g[0].object_id == gstr_id,
       "B5: guarded box string identity preserved (dcompact kept VALUE fresh via rb_gc_location)")

# ---------------------------------------------------------------- part C
# The unguarded box may be corrupted SO badly that merely reading it
# segfaults or aborts the VM (observed: dangling VALUE fed to
# id_table_lookup -> SIGSEGV; also glibc aborts from corrupted frees).
# fork() is NOT safe here (D rt_init state does not survive fork — the
# child's abort poisoned the parent too), so part C runs as a separate
# process: the script re-execs itself with EXP_PART_C=1. A crash or
# garbage read there is the finding-#11 reproduction; a clean read is
# luck (conservative GC roots), so neither outcome is a test failure —
# this part is a witness.

if ENV["EXP_PART_C"]
  $stdout.sync = true
  ubox, ustr_id, uarr_id = make_unguarded
  GC.start; GC.compact; GC.start
  churn
  GC.start; GC.compact; GC.start
  churn
  GC.start; GC.compact; GC.start
  u = DExpCompact.read_box(ubox)
  u_intact = u[0].is_a?(String) && u[0].start_with?("U-") &&
             u[1].is_a?(Array) && u[1][0, 3] == [1, 2, 3]
  u_alive = alive?(ustr_id)
  puts "CHILD-RESULT intact=#{u_intact} alive=#{u_alive}"
  exit!(u_intact && u_alive ? 0 : 3)       # 3 = corruption observed
end

partc = system({ "EXP_PART_C" => "1" }, RbConfig.ruby, __FILE__,
               out: "/dev/null", err: "/dev/null")
if partc
  puts "C (diagnostic): unguarded box survived this run (conservative GC roots delayed collection) — corruption not observed, not asserted"
elsif $?.exitstatus == 3
  puts "C (diagnostic): CORRUPTION OBSERVED in unguarded box (collected referents / garbage read-back) — finding #11 reproduced"
else
  puts "C (diagnostic): unguarded box read CRASHED (signal/abort, status #{$?.exitstatus}) — finding #11 reproduced: use-after-free crashes the VM"
end

# ---------------------------------------------------------------- verdict

if $failures > 0
  puts "EXP COMPACT: #{$failures} FAILURES of #{$count}"
  exit 1
else
  puts "EXP COMPACT PASS: all #{$count} assertions green"
  exit 0
end