# EXP 2 — D<->Ruby two-way boundary crossing
require_relative "../test/dextest_loader"
require File.expand_path("../#{ENV.fetch("RUDY_BUILD_DIR", ".build")}/exp_cross.so", __dir__)

module ExpCross
  # shoelace helper D calls back into — proves D can invoke Ruby
  def self.shoelace(pts)
    pts.each_cons(2).sum(0.0) { |(x1, y1), (x2, y2)| x1 * y2 - x2 * y1 } / 2.0
  end
end

# 1. D sorts a Ruby array using a Ruby block, via rb_protect
ary = [5, 3, 8, 1, 9, 2]
ExpCross.register_ary(ary)
ExpCross.register_block(proc { |a, b| a <=> b })
puts "D-sorted:   #{ExpCross.sort_with_block!.inspect}   (expect [1,2,3,5,8,9])"
raise "sort wrong" unless ExpCross.sort_with_block! == [1, 2, 3, 5, 8, 9]

# block that raises — must be caught by rb_protect and re-raised as RuntimeError
ExpCross.register_block(proc { |a, b| raise "boom" })
begin
  ExpCross.sort_with_block!
  raise "expected raise"
rescue RuntimeError => e
  puts "rb_protect caught block raise: #{e.message}"
end

# 2. D builds nested structure, calls back into Ruby shoelace
area = ExpCross.polygon_area
puts "area:       #{area}   (expect 1.0 — unit square)"
raise "area wrong" unless (area - 1.0).abs < 1e-9

# 3. fixed-arity sum
puts "sum3:       #{ExpCross.sum3(1.5, 2.5, 3.0)}   (expect 7.0)"
raise "sum3 wrong" unless (ExpCross.sum3(1.5, 2.5, 3.0) - 7.0).abs < 1e-9

# 4. raise from deep D recursion
begin
  ExpCross.raise_from_deep(50)
  raise "expected RangeError"
rescue RangeError => e
  puts "deep raise unwound 50 D frames: #{e.message}"
end

puts "EXP 2 PASS"