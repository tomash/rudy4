# lib/hello_gem.rb
#
# Pure-Ruby half of the gem. Its job: load the compiled native extension and
# provide the conventional `HelloGem` namespace. Native code is written in D
# (see ext/hello_gem/hello_gem.d) and compiled by extconf.rb via GDC.

require "hello_gem/version"

# `hello_gem_ext.so` is installed into this directory by the gem's install
# step. (The native artifact is suffixed `_ext` so it does not collide with
# this file, `hello_gem.rb`.)
begin
  require "hello_gem_ext"
rescue LoadError => e
  raise LoadError, <<~MSG
    Could not load the native hello_gem extension (#{e.message}).
    Build it first:
      cd ext/hello_gem && ruby extconf.rb && make && make install
  MSG
end

module HelloGem
  # A small pure-Ruby convenience on top of the native Vec2: a unit vector.
  # `HelloVec2` itself comes from D land.
  def self.unit(x, y)
    v = HelloVec2.new(x, y)
    n = Math.sqrt(v.norm2)
    return v if n.zero?

    HelloVec2.new(x / n, y / n)
  end
end
