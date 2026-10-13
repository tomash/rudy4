# frozen_string_literal: true

require_relative "lib/rudy4/version"

Gem::Specification.new do |spec|
  spec.name    = "rudy4"
  spec.version = Rudy4::VERSION
  spec.authors = ["Tomasz Stachewicz"]
  spec.email   = ["tomasz.stachewicz@gmail.com"]

  spec.summary     = "Write Ruby native extensions in D"
  spec.description = <<~DESC
    rudy4 lets you write Ruby native extensions in D (compiled by GDC) instead
    of C. This gem ships the rudy4 D library plus the `rudy4` command: `rudy4
    init NAME` scaffolds a self-contained extension gem (vendoring the D
    sources, so it builds with no checkout), and `rudy4 doctor` checks your
    Ruby + GDC setup by compiling and loading a probe extension.
  DESC
  spec.homepage = "https://github.com/tomash/rudy4"
  spec.license  = "MIT"

  spec.required_ruby_version = ">= 4.0"

  spec.files = Dir[
    "lib/**/*.rb",
    "bin/*",
    "vendor/**/*.d",
    "examples/**/*",
    "src/**/*.d",
    "experiments/**/*.d",
    "test/**/*.rb",
    "scripts/*",
    "Makefile",
    "README.md",
    "LICENSE",
    "CHANGELOG.md",
  ].select { |path| File.file?(path) }

  spec.bindir      = "bin"
  spec.executables = ["rudy4"]
  spec.require_paths = ["lib"]

  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = spec.homepage
end
