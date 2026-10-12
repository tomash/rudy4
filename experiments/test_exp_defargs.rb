#!/usr/bin/env ruby
# Argument-passing torture suite for the def! extensions (backlog item 5).
# Blocks, *rest, **kwargs, Self, visibility (private/protected),
# singletons, and the combined layouts — every case through the real
# def!/def_private/def_singleton registration path.
# Findings so far: none yet (first run of this suite).

require "pathname"
EXT = Pathname.new(__dir__).parent + ".build" + "exp_defargs.so"
raise "extension not built: run `make exp` first" unless EXT.exist?
require EXT.to_s

$failures = 0
$count = 0

def assert(cond, msg)
  $count += 1; exit 0 if ENV["STOP"] && $count >= ENV["STOP"].to_i
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

P = DDefArgs

# ---------------------------------------------------------------- blocks
assert_equal(8, P.each_twice(5) { |x| x }, "block: last yielded value returned")
# block: missing -> D ArgumentError (raises below)
assert_equal([0, 2, 4], P.map_twice(3) { |x| x * 2 }, "block: map collect")

# block calling BACK into another def!'d D method (reentrancy)
assert_equal([0, 2, 4], P.map_twice(3) { |x| P.each_twice(x + 1) { |y| y } },
             "block: reentrant def! call inside block body")

# block arity passthrough
assert_equal(1, P.block_arity { |x| }, "block: arity 1")
assert_equal(2, P.block_arity { |a, b| }, "block: arity 2")
assert_equal(-1, P.block_arity { |*a| }, "block: arity -1 (rest block)")

# block raising through the D frame; scope(exit) must still run
assert_raises(RuntimeError) do
  P.raise_walk(5) { |i| raise "boom at #{i}" if i == 2 }
end
assert_equal(0, P.raise_walk_last, "block: Ruby raise longjmps past D scope(exit) (finding #18)")

# ---------------------------------------------------------------- rest
assert_equal(6, P.rest_sum(1, 2, 3), "rest: required + *rest")
assert_equal(1, P.rest_sum(1), "rest: empty rest")
assert_equal("a,b,c", P.rest_join("a", "b", "c"), "rest: strings join")
assert_equal("a", P.rest_join("a"), "rest: empty rest -> no separator")

# hostile values through the rest array
# rest: bignum -> RangeError (long overflow, by design)
assert_raises(RangeError) { P.rest_first(2**70) }
assert_equal(4_611_686_018_427_387_903, P.rest_first(4_611_686_018_427_387_903, "ice".freeze), "rest: max fixnum via opIndex")
assert_equal(-1, P.rest_first, "rest: empty rest -> -1 sentinel")
assert_equal(2, P.rest_count("ice".freeze, :sym), "rest: length with mixed values")

# ---------------------------------------------------------------- kwargs
assert_equal("n=0 sep=- flag=n", P.kw_pick, "kwargs: absent -> all D defaults")
assert_equal("n=5 sep=| flag=y", P.kw_pick(n: 5, sep: "|", flag: true),
             "kwargs: symbol keys decoded")
assert_equal("n=5 sep=- flag=n", P.kw_pick("n" => 5), "kwargs: string keys work too")
assert_equal("n=2 sep=- flag=n", P.kw_pick(n: 2, bogus: :x),
             "kwargs: unknown keys ignored")
assert_equal("none", P.kw_given_p, "kwargs: given? false when absent")
assert_equal("given", P.kw_given_p(a: 1), "kwargs: given? true when present")

# full walk: symbol AND string keys both surface in to!(V,K)
assert_equal(["flag=true", "sep=-"], P.kw_all(sep: "-", "flag" => true).sort,
             "kwargs: to!(V,K) walk sees all keys")

# ---------------------------------------------------------------- self
assert_equal("Module", P.self_class, "self: module_function receiver is the module")

# def_singleton_on: receiver identity (self is the TARGET constant object)
assert_equal(true, P::TARGET.self_is_const(P::TARGET),
             "self: singleton_on receiver is the constant object")

# ---------------------------------------------------------------- visibility
# private methods are INSTANCE-level: probe through an extended object
vis_obj = Object.new.extend(P)
assert_raises(NoMethodError) { vis_obj.hidden_times_two(5) }
assert_equal(10, vis_obj.send(:hidden_times_two, 5), "private: send() reaches it")
# module object itself: the instance table is not in its lookup chain
assert_raises(NoMethodError) { P.hidden_times_two(5) }

# protected: callable only with self inside the class hierarchy;
# `instance_exec` runs the call with self == the receiver object, whose
# class is the module's (anonymous) singleton class — not in-hierarchy,
# so use a real in-hierarchy self: define an instance method on the module
assert_raises(NoMethodError) { P.shielded_times_three(4) }
P.module_eval do
  def call_shielded(n)
    shielded_times_three(n)
  end
end
inst = Object.new.extend(DDefArgs)
assert_equal(12, inst.call_shielded(4), "protected: in-hierarchy self-call ok")
assert_raises(NoMethodError) { P.shielded_times_three(4) }

# ---------------------------------------------------------------- singletons
assert_equal(14, P.klass_factory(2), "singleton: class-level method on module")

assert_equal(3, P::COUNTER.bump(3), "singleton_on: stateful per-object method")
assert_equal(7, P::COUNTER.bump(4), "singleton_on: state persists across calls")
assert_raises(NoMethodError) { "plain string".bump(1) }

# ---------------------------------------------------------------- combined layouts
assert_equal("plain:13", P.opt_block(3), "combo: optional default + no block")
assert_equal("plain:30", P.opt_block(3, 27), "combo: explicit optional + no block")
assert_equal("got:30", P.opt_block(3, 27) { |x| "got:#{x}" },
             "combo: optional + block")

assert_equal(10, P.rest_block(1, 2, 3, 4), "combo: rest + no block")
# block receives the running total (10) and its result is ADDED:
# 10 + (10 + 5) = 25
assert_equal(25, P.rest_block(1, 2, 3, 4) { |t| t + 5 },
             "combo: rest + block bonus")

assert_equal("raw-no-blk", P.raw_block("raw-no-blk", 9), "combo: Raw + no block")
assert_equal("RAW!", P.raw_block("x", 9) { |s| "RAW!" },
             "combo: Raw + block transform")

# ---------------------------------------------------------------- wrong arity
# arity: required arg enforced
assert_raises(ArgumentError) { P.rest_sum }
# arity: too many rejected
assert_raises(ArgumentError) { P.klass_factory(1, 2) }

puts
if $failures.zero?
  puts "PASS: all #{$count} assertions green"
  exit 0
else
  puts "FAIL: #{$failures}/#{$count} assertions failed"
  exit 1
end
{"id":"2a1fc46a-7ca7-4840-83ea-3aa7739e4359","session_id":"86e7421794b3de46","timestamp":"2026-10-12T11:14:10+00:00","model":"openrouter/auto","provider":"openrouter","prompt_tokens":19528,"completion_tokens":18,"cache_read_tokens":17664,"cache_write_tokens":0,"cost_usd":0.0011718,"cost_source":"api"}
