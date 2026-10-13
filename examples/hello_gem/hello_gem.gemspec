# frozen_string_literal: true

require_relative "lib/hello_gem/version"

Gem::Specification.new do |spec|
  spec.name    = "hello_gem"
  spec.version = HelloGem::VERSION
  spec.authors = ["Tomasz Stachewicz"]
  spec.email   = ["tomasz.stachewicz@gmail.com"]

  spec.summary     = "A D-backed Ruby extension, packaged as a gem"
  spec.description = <<~DESC
    Reference example for rudy4: the native half of this gem is written in D
    (compiled by GDC) and exposes global functions plus a wrapped D struct to
    Ruby. Shows the gem-shaped layout (gemspec + ext/ + lib/) that a real
    rudy4-based extension would ship with.
  DESC
  spec.homepage = "https://github.com/tomash/rudy4"
  spec.license  = "MIT"

  spec.required_ruby_version = ">= 4.0"

  spec.files = Dir[
    "lib/**/*.rb",
    "ext/**/*.d",
    "ext/**/*.rb",
    "README.md",
  ]
  spec.require_paths = ["lib"]

  # Builds hello_gem.so from D sources via GDC.
  spec.extensions = ["ext/hello_gem/extconf.rb"]

  spec.metadata["rubygems_mfa_required"] = "true"
end
