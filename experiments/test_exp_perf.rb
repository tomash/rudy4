# EXP 3 — performance & GC torture
require_relative "../test/dextest_loader"
require File.expand_path("../#{ENV.fetch("RUDY_BUILD_DIR", ".build")}/exp_perf.so", __dir__)

def bench(label)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  r = yield
  t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  puts format("%-32s %8.1f ms  -> %s", label, (t1 - t0) * 1000, r.inspect)
  r
end

# constants defined from D
raise "PI const wrong" unless (ExpPerf::PI - Math::PI).abs < 1e-9
puts "ExpPerf::GREETING = #{ExpPerf::GREETING.inspect}"

# pure D fib vs boundary-crossing fib
bench("fib(28) pure D")        { ExpPerf.fib(28) }
bench("fib(18) every lvl Ruby") { ExpPerf.fib_boundary(18) }

# big array build + sum
ary, total = ExpPerf.build(100_000)
bench("build 100k Float array") { ExpPerf.build(100_000) }
raise "build sum wrong" unless (total - 100_000 * 99_999 * 0.25).abs < 1e9

# hash conversion
h = bench("10k-entry D AA -> Hash") { ExpPerf.hash(10_000) }
raise "hash size wrong" unless h.size == 10_000
raise "hash value wrong" unless h[9999] == 9999 * 9999

# GC running while D holds things
GC.start
puts "EXP 3 PASS"