# EXP 1 — wrap a real D struct as a Ruby object (DMatrix)
require_relative "../test/dextest_loader"
require File.expand_path("../#{ENV.fetch("RUDY_BUILD_DIR", ".build")}/exp_wrap.so", __dir__)

m = DMatrix.new(3, 3)
[[2, 0, 1], [0, 3, 0], [1, 0, 2]].each_with_index do |row, r|
  row.each_with_index { |v, c| m[r, c] = v }
end
puts "m.to_a        = #{m.to_a.inspect}"
puts "m.det         = #{m.det}   (expect 9.0)"
raise "det wrong" unless (m.det - 9.0).abs < 1e-9

big = DMatrix.new(10, 10)
10.times { |r| 10.times { |c| big[r, c] = (r == c) ? 1.0 : 0.0 } }
big[3, 3] = 3.5
big[7, 0] = 2.0   # below-diagonal perturbation must not change det
puts "big.det       = #{big.det}   (expect 3.5 — I with [3,3]=3.5)"
raise "10x10 det wrong" unless (big.det - 3.5).abs < 1e-9

puts "GC stress: 100_000 wrapped matrices..."
before = `ps -o rss= -p #{Process.pid}`.to_i
m2 = DMatrix.new(4, 4)
m2.stress(100_000)
after = `ps -o rss= -p #{Process.pid}`.to_i
puts "RSS: #{before} -> #{after} KB (delta #{after - before} KB)"
raise "leak? RSS grew #{after - before} KB" if after - before > 50_000
puts "EXP 1 PASS"
