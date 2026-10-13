#!/usr/bin/env ruby
# EXPERIMENT 11 — Documented non-goals (backlog item 9).
#
# Evidence for three "we do not promise this" boundaries, so the limits are
# visible rather than silent:
#
#   1. Fiber switching across D frames. A Ruby Fiber switches stacks
#      underneath D frames. Probes here show the *supported* subset:
#      simple value round-trips across a switch work — a D frame, being a
#      plain C frame, survives the fiber switch, and a wrapped struct's
#      payload stays valid. NOT promised: relying on a D GC heap object
#      that is only reachable from a fiber-stack local (D's GC scans the
#      thread stack, not Ruby's per-fiber stacks).
#
#   2. Ractor-shareability. A def!'d method is registered without the
#      ractor-safe declaration (rb_ext_ractor_safe), so Ruby refuses to
#      call it from a non-main Ractor (Ractor::UnsafeError). A D-wrapped
#      object is an opaque non-Ruby object with a D-runtime-owned payload:
#      not shareable, not movable between Ractors. Probes assert the
#      refusal, and that the main Ractor keeps working afterwards.
#
#   3. Interruptibility of a long GVL-held D call. While D holds the GVL,
#      Ruby cannot run its interrupt checks: a SIGINT during a 2.5 s
#      GVL-held D call is only delivered when the call returns. Releasing
#      the GVL (rb_thread_call_without_gvl + a cooperating unblock func)
#      makes the same wait interruptible in ~0.4 s. Asserted with
#      subprocesses (fork() is unsafe with a dlopen'd D .so — NOTES.md).

require "pathname"
Warning[:experimental] = false if Warning.respond_to?(:[]=)
EXT = Pathname.new(__dir__).parent + ENV.fetch("RUDY_BUILD_DIR", ".build") + "exp_nonregression.so"
raise "exp_nonregression not built: run `make exp` first" unless EXT.exist?
require EXT.to_s

Ractor.report_on_exception = false if Ractor.respond_to?(:report_on_exception=)
Thread.report_on_exception = false if Thread.respond_to?(:report_on_exception=)

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

# =====================================================================
# child mode: the interruptibity probe re-execs itself (see NOTES.md —
# fork() is not safe once a D runtime is initialised in the process)
# =====================================================================
if (mode = ENV["NONREG_CHILD"])
  $stdout.sync = true
  ms = Integer(ENV.fetch("NONREG_MS", "2500"))
  begin
    case mode
    when "gvl"
      DNonReg.sleep_gvl(ms)
    when "nogvl"
      DNonReg.nap_nogvl(ms)          # cooperative ubf
    when "nogvl_raise"
      Thread.new { sleep 0.4; Thread.main.raise(Interrupt) }
      DNonReg.nap_nogvl(ms)
    end
    puts "completed:#{mode}"
  rescue Interrupt
    puts "interrupted:#{mode}"
  end
  exit! 0
end

# =====================================================================
# 1. Fiber switching across D frames
# =====================================================================
puts "--- fiber: D frame on top of a fiber switch (supported subset)"

b = DNonRegBox.new(1.5, 2.5)

f = Fiber.new do
  # Fiber.yield runs INSIDE the D call's frame: the D frame is suspended
  # and later resumed by the Ruby scheduler.
  after = b.roundtrip { Fiber.yield b[0] }
  Fiber.yield after
  :done
end

assert_equal(1.5, f.resume, "fiber: value yielded from inside the D frame")
assert_equal(1.5, f.resume, "fiber: D frame resumed, wrapped struct intact")
assert_equal(:done, f.resume, "fiber: fiber completes after the D call returns")

# D objects created *inside* a fiber body: construction, method calls and
# a pure-D computation all work on the fiber stack.
f2 = Fiber.new do
  b2 = DNonRegBox.new(1.0, 2.0)
  [DNonReg.fib(15), b2[0], b2[1]]
end
assert_equal([610, 1.0, 2.0], f2.resume, "fiber: D object created and used inside a fiber body")

# many switches with D frames repeatedly pushed/popped on the fiber stack
f3 = Fiber.new do
  acc = 0
  100.times do |i|
    acc += b.roundtrip { Fiber.yield i }
  end
  acc
end
100.times { f3.resume }
assert_equal(100 * 1.5, f3.resume, "fiber: 100 switch round-trips through a D frame")

# =====================================================================
# 2. Ractor shareability (asserted refusal, not support)
# =====================================================================
puts "--- ractor: non-shareability is enforced by the VM"

def ractor_refusal(reason)
  yield
  [nil, "no error raised (#{reason})"]
rescue Exception => e
  chain = [e]
  chain << chain.last.cause while chain.last.cause && chain.size < 5
  refused = chain.any? { |x| x.class.name.to_s.start_with?("Ractor") }
  [refused, "#{e.class}: #{e.message.to_s.lines.first.to_s.strip}"]
end

ok, info = ractor_refusal("pure D call from a Ractor") { Ractor.new { DNonReg.fib(10) }.value }
assert(ok, "ractor: pure def!'d D call from a non-main Ractor is refused (#{info})")

ok, info = ractor_refusal("D object built inside a Ractor") { Ractor.new { DNonRegBox.new(1.0, 2.0)[0] }.value }
assert(ok, "ractor: building a D-wrapped object inside a Ractor is refused (#{info})")

ok, info = ractor_refusal("D object referenced by a Ractor") { Ractor.new(b) { |x| x[0] }.value }
assert(ok, "ractor: passing a D-wrapped object to a Ractor is refused (#{info})")

frozen_box = DNonRegBox.new(3.0, 4.0).freeze
ok, info = ractor_refusal("frozen D object referenced by a Ractor") { Ractor.new(frozen_box) { |x| x[0] }.value }
assert(ok, "ractor: even a frozen D-wrapped object is not shareable (#{info})")

ok, info = ractor_refusal("D runtime allocation inside a Ractor") { Ractor.new { DNonReg.helper_check }.value }
assert(ok, "ractor: D-runtime allocation inside a Ractor is refused (#{info})")

# main Ractor keeps working after every refused Ractor — no corruption
assert_equal(55, DNonReg.fib(10), "ractor: main Ractor still calls D after Ractor refusals")
assert_equal(42, DNonReg.helper_check, "ractor: main Ractor still allocates D objects afterwards")
assert_equal(true, Ractor.main == Ractor.current, "ractor: still running in the main Ractor")

# =====================================================================
# 3. Interruptibility of a long GVL-held D call
# =====================================================================
puts "--- interruptibility: GVL-held D call is late; GVL-released is prompt"

WAIT_MS = 2500

def interrupt_probe(mode, signal:)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  out_r = "/tmp/nonreg_#{mode}.out"
  env = { "NONREG_CHILD" => mode, "NONREG_MS" => WAIT_MS.to_s }
  env["RUDY_BUILD_DIR"] = ENV["RUDY_BUILD_DIR"] if ENV["RUDY_BUILD_DIR"]
  pid = Process.spawn(env, RbConfig.ruby, __FILE__, out: out_r, err: "/tmp/nonreg.err")
  sleep 0.4
  Process.kill(signal, pid) if signal
  _, status = Process.wait2(pid)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  [elapsed, status, File.read(out_r).strip]
end

gvl_elapsed, gvl_status, gvl_out = interrupt_probe("gvl", signal: "INT")
assert_equal("interrupted:gvl", gvl_out, "interrupt: SIGINT reached the GVL-held D call (at return)")
assert(gvl_elapsed >= WAIT_MS / 1000.0 * 0.7,
       "interrupt: GVL-held D call ignored SIGINT until it returned (#{format('%.2f', gvl_elapsed)}s for a #{WAIT_MS}ms wait)")

ng_elapsed, ng_status, ng_out = interrupt_probe("nogvl", signal: "INT")
assert_equal("interrupted:nogvl", ng_out, "interrupt: SIGINT interrupted the GVL-released D call")
assert(ng_elapsed < 2.0,
       "interrupt: GVL-released D call stopped promptly (#{format('%.2f', ng_elapsed)}s for a #{WAIT_MS}ms wait)")

nr_elapsed, nr_status, nr_out = interrupt_probe("nogvl_raise", signal: nil)
assert_equal("interrupted:nogvl_raise", nr_out, "interrupt: Thread#raise on main interrupted the GVL-released call")
assert(nr_elapsed < 2.0,
       "interrupt: Thread#raise path is prompt too (#{format('%.2f', nr_elapsed)}s)")

assert(ng_elapsed < gvl_elapsed,
       "interrupt: releasing the GVL is what makes a long D call interruptible")

# ---------------------------------------------------------------- verdict

if $failures > 0
  puts "EXP NONREGRESSION: #{$failures} FAILURES of #{$count}"
  exit 1
else
  puts "EXP NONREGRESSION PASS: all #{$count} assertions green"
  exit 0
end
