#!/usr/bin/env ruby
# Conversion property suite for rudy/convert.d (backlog item 4).
# Round-trip property: for every supported type, D→Ruby→D is lossless —
# long.min, NaN/±0.0/inf, empty/NUL/binary/non-UTF-8 strings, frozen
# strings, truthiness edges, hostile coercions, GC pressure mid-call.
# Findings so far: #12 (rb_str_strlen chars-vs-bytes truncation).

require "pathname"
EXT = Pathname.new(__dir__).parent + ".build" + "exp_convert.so"
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

P = ConvertProbe

# ---------------------------------------------------------------- integers
LONG_EDGES = [0, 1, -1, 42, 4611686018427387903, -4611686018427387904,
              (2**62), -(2**62), 9_223_372_036_854_775_807,
              -9_223_372_036_854_775_808].freeze
LONG_EDGES.each do |n|
  assert_equal(n, P.long(n), "long round trip #{n}")
end
ULONG_EDGES = [0, 1, 42, 9_223_372_036_854_775_807, 18_446_744_073_709_551_615].freeze
ULONG_EDGES.each do |n|
  assert_equal(n, P.ulong(n), "ulong round trip #{n}")
end
INT_EDGES = [0, 1, -1, 2_147_483_647, -2_147_483_648].freeze
INT_EDGES.each do |n|
  assert_equal(n, P.int(n), "int round trip #{n}")
end
UINT_EDGES = [0, 1, 4_294_967_295].freeze
UINT_EDGES.each do |n|
  assert_equal(n, P.uint(n), "uint round trip #{n}")
end

# Numeric coercions Ruby itself allows / rejects — NUM2LONG semantics
assert_equal(42, P.long(42.0), "integral Float -> long")
assert_equal(42, P.long(42.5), "fractional Float truncates toward zero (NUM2LONG semantics)")
assert_raises(TypeError)       { P.long("nonsense") }
assert_raises(TypeError)       { P.long(nil) }
assert_raises(TypeError)       { P.long(:sym) }

# Out-of-range for the D type: must raise, not silently truncate (finding #13)
assert_raises(RangeError) { P.int(2_147_483_648) }        # 2**31 — > INT_MAX
assert_raises(RangeError) { P.uint(-1) }
assert_raises(RangeError) { P.long(2**100) }              # bignum
assert_raises(RangeError) { P.ulong(-1) }
assert_raises(RangeError) { P.uint(4_294_967_296) }
assert_raises(RangeError) { P.int(-2_147_483_649) }
assert_raises(RangeError) { P.long(Float::NAN) }   # NUM2LONG: RangeError (FloatDomainError is its subclass)
assert_raises(RangeError) { P.int(Float::INFINITY) }
assert_raises(RangeError) { P.uint(Float::INFINITY) }

# ---------------------------------------------------------------- floats
DOUBLE_EDGES = [0.0, -1.5, 3.141592653589793, 1.0e308, -1.0e308,
                4.9e-324, 2.2250738585072014e-308].freeze
DOUBLE_EDGES.each do |f|
  assert_equal(f, P.double(f), "double round trip #{f}")
end
nan = P.double(Float::NAN)
assert(nan.nan?, "NaN round trip: got #{nan.inspect}")
assert_equal(1,  P.double(Float::INFINITY).infinite?, "+inf round trip")
assert_equal(-1, P.double(-Float::INFINITY).infinite?, "-inf round trip")
neg_zero = P.double(-0.0)
assert(neg_zero.zero? && (1.0 / neg_zero) < 0, "-0.0 survives (sign bit)")
assert(nan.nan?, "NaN Float passes through d_type!double")
assert_raises(TypeError) { P.double("zap") }

# ---------------------------------------------------------------- strings: the finding #12 family
STR_EDGES = ["", "hello", "\x00", "a\x00b", "line\nbreak\ttab",
             "héllo wörld ✓ ✓",                       # valid multibyte UTF-8
             "\xff\xfe invalid utf8",                  # invalid UTF-8 bytes
             "\xA4\xA2".dup.force_encoding("EUC-JP"),  # non-UTF-8 encoding
             (0..255).map { |b| b.chr }.join           # every byte value
            ].freeze
STR_EDGES.each do |s|
  out = P.string(s)
  bytes = s.dup.force_encoding("BINARY")
  assert_equal(bytes.bytesize, out.bytesize, "string bytesize preserved #{bytes.inspect[0, 24]}")
  assert_equal(bytes, out.dup.force_encoding("BINARY"), "string bytes preserved #{bytes.inspect[0, 24]}")
end

# frozen input: D copies, result must be a fresh unfrozen String
frozen = "frozen string".freeze
out = P.string(frozen)
assert_equal(frozen, out, "frozen string bytes round trip")
assert(!out.frozen?, "result of frozen-string round trip is unfrozen (D made a copy)")

# Random binary fuzz: 200 strings, random lengths, all byte values
srand(0x24E5_2026)
200.times do |i|
  s = Array.new(rand(0..64)) { rand(0..255).chr }.join
  out = P.string(s)
  if out != s
    assert(false, "fuzz #{i}: #{s.inspect} -> #{out.inspect}")
  else
    $count += 1; puts "ok #{$count} - fuzz #{i}: binary #{s.bytesize}B round trip"
  end
end

# d_type!string must decode ANY String — empty, NUL-laden, binary,
# non-UTF-8 — and preserve the exact byte count (finding #12 check).
STR_EDGES.take(4).each do |s|
  assert_equal(s.bytesize, P.string_bytesize(s), "bytesize preserved #{s.inspect[0, 24]}")
end
assert_equal(0, P.string_bytesize(""), "empty string: bytesize 0")
assert_equal(3, P.string_bytesize("a\x00b"), "NUL-laden string: bytesize 3")

# ---------------------------------------------------------------- bool: RUBY_TEST truthiness (finding #14)
assert_equal(true,  P.bool(true),  "true -> true")
assert_equal(false, P.bool(false), "false -> false")
assert_equal(false, P.bool(nil),   "nil -> false")
# Everything else is RUBY_TEST truthy in Ruby — including 0, 0.0, "":
[0, 0.0, "", [], {}, Object.new, :sym].each do |v|
  assert_equal(true, P.bool(v), "Ruby truthiness: #{v.inspect} -> true (RUBY_TEST, not RTEST==Qtrue)")
end

# ---------------------------------------------------------------- symbols: reject, not corrupt
assert_equal("ok", P.sym_to_s(:ok), "Symbol -> to_s via D")
s = "héllo ✓ sym"
assert_equal(s, P.sym_roundtrip(s), "String -> Symbol -> String byte-perfect")
assert_raises(TypeError) { P.string(:a_symbol) }   # no implicit conversion
assert_raises(TypeError) { P.string(nil) }

# ---------------------------------------------------------------- GC pressure: strings mid-conversion
GC.stress = true
STR_EDGES.take(4).each do |s|
  assert_equal(s.dup.force_encoding("BINARY"),
               P.string_stress(s).dup.force_encoding("BINARY"),
               "GC.stress string round trip #{s.inspect[0, 20]}")
end
LONG_EDGES.take(4).each do |n|
  assert_equal(n, P.long(n), "GC.stress long round trip #{n}")
end
GC.stress = false

puts
if $failures.zero?
  puts "PASS: all #{$count} assertions green"
  exit 0
else
  puts "FAIL: #{$failures}/#{$count} assertions failed"
  exit 1
end
