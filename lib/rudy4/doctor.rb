# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"

require_relative "error"
require_relative "generator"
require_relative "vendor"
require_relative "version"

module Rudy4
  # `rudy4 doctor` — check that this machine can actually build a D-backed
  # Ruby extension, and prove it by scaffolding and compiling a throwaway
  # extension. Every failure carries a fix, not just a diagnosis.
  class Doctor
    Error = Rudy4::Error
    # Runtime/toolchain combinations rudy4 has been tested against. Anything
    # else gets a warning, never a hard failure — the point is to be honest
    # about what is verified, not to refuse to try.
    TESTED_RUBY_MAJOR  = "4"
    MIN_GDC_MAJOR      = 13
    GDC_CANDIDATES     = ["gdc-14", "gdc-13", "gdc-12", "gdc"].freeze

    PASS  = "ok"
    WARN  = "warn"
    FAIL  = "fail"

    Check = Struct.new(:status, :label, :detail, :fix)

    def initialize(quick: false, out: $stdout)
      @quick = quick
      @out   = out
      @checks = []
    end

    def call
      @out.puts "rudy4 doctor — #{Rudy4::VERSION} on ruby #{RUBY_VERSION} (#{RUBY_PLATFORM})"
      @out.puts

      check_ruby
      check_ruby_headers
      check_shared_libruby
      check_gdc
      check_vendored_sources
      check_build unless @quick

      report
    end

    private

    def add(status, label, detail = nil, fix = nil)
      @checks << Check.new(status, label, detail, fix)
    end

    # --- individual checks ---------------------------------------------------

    def check_ruby
      major = RUBY_VERSION.split(".").first
      if major == TESTED_RUBY_MAJOR
        add PASS, "ruby #{RUBY_VERSION}", "matches the tested 4.x C API"
      else
        add WARN, "ruby #{RUBY_VERSION}",
                 "rudy4 is only tested against Ruby #{TESTED_RUBY_MAJOR}.x",
                 "Expect compile or ABI problems on Ruby #{major}.x; pin Ruby 4.x for now."
      end
    end

    def check_ruby_headers
      hdr     = RbConfig::CONFIG["rubyhdrdir"]
      archhdr = RbConfig::CONFIG["rubyarchhdrdir"]

      if hdr && File.directory?(hdr) && File.file?(File.join(hdr, "ruby.h"))
        add PASS, "ruby headers", hdr
      else
        add FAIL, "ruby headers",
                 "ruby.h not found (#{hdr.inspect})",
                 "Install the development headers: `apt-get install ruby-dev` " \
                 "(Debian/Ubuntu) or `ruby-devel` (Fedora), or use a Ruby built with headers."
      end

      if archhdr && File.directory?(archhdr)
        add PASS, "ruby arch headers", archhdr
      else
        add FAIL, "ruby arch headers",
                 "rubyarchhdrdir not found (#{archhdr.inspect})",
                 "Same fix as ruby headers — they ship together (ruby-dev / ruby-devel)."
      end
    end

    def check_shared_libruby
      libarg = RbConfig::CONFIG["LIBRUBYARG_SHARED"].to_s
      libdir = RbConfig::CONFIG["libdir"].to_s

      if libarg.empty?
        add FAIL, "shared libruby",
                 "this Ruby has no LIBRUBYARG_SHARED",
                 "The extension links against libruby.so, so Ruby must be built " \
                 "with --enable-shared. Rebuild Ruby with that flag (or install a " \
                 "distro/shared build)."
      else
        add PASS, "shared libruby", "#{libarg} (in #{libdir})"
      end
    end

    def check_gdc
      @gdc = detect_gdc

      unless @gdc
        add FAIL, "gdc (D compiler)",
                 "no GDC binary found (looked for #{GDC_CANDIDATES.join(', ')})",
                 "Install it — Ubuntu 24.04: `apt-get install gdc-14`; " \
                 "see https://gdcproject.org/downloads. Set $GDC to point at a specific binary."
        return
      end

      version = @gdc_version = gdc_version(@gdc)
      major   = version&.split(".")&.first.to_i

      if version.nil?
        add WARN, "gdc (D compiler)", "#{@gdc} (version not parsed)"
      elsif major >= MIN_GDC_MAJOR
        detail = "#{@gdc} — GDC #{version}"
        detail += ", matches the tested GDC 14" if major == 14
        add PASS, "gdc (D compiler)", detail
      else
        add WARN, "gdc (D compiler)",
                 "#{@gdc} — GDC #{version} (older than the required #{MIN_GDC_MAJOR})",
                 "Upgrade to GDC 14 (`apt-get install gdc-14`); rudy4 uses D features " \
                 "older front-ends do not implement."
      end
    end

    def check_vendored_sources
      if Vendor.present?
        count = Vendor.d_sources.length
        add PASS, "vendored rudy4 sources", "#{count} .d files in #{Vendor.rudy_dir}"
      else
        add FAIL, "vendored rudy4 sources",
                 "missing from #{Vendor.rudy_dir}",
                 "Reinstall the gem: `gem install rudy4`."
      end
    end

    # The real test: scaffold a throwaway extension, build it with GDC, load it.
    def check_build
      unless @gdc && Vendor.present?
        add WARN, "build smoke test", "skipped (fix the failures above first)"
        return
      end

      Dir.mktmpdir("rudy4-doctor-") do |tmp|
        name = "doctor_probe"
        generator = Generator.new(name, parent_dir: tmp, out: StringIO.new)
        generator.call

        ext_dir = File.join(tmp, name, "ext", name)
        ok, output = run_build(ext_dir)

        unless ok
          add FAIL, "build smoke test",
                   "GDC could not compile a scaffolded extension",
                   "Compiler output:\n#{indent(output)}"
          return
        end

        loaded, detail = run_load(File.join(tmp, name, "lib"), name)
        if loaded
          add PASS, "build smoke test", "compiled and loaded a scaffolded extension (#{detail})"
        else
          add FAIL, "build smoke test",
                   "the extension compiled but could not be loaded",
                   detail
        end
      end
    rescue Generator::Error => e
      add FAIL, "build smoke test", e.message, nil
    end

    def run_build(ext_dir)
      env = { "GDC" => File.basename(@gdc) }
      output = +""
      lib_dir = File.expand_path("../../lib", ext_dir)

      ok = Dir.chdir(ext_dir) do
        FileUtils.rm_f("Makefile")

        out1, err1, st1 = Open3.capture3(env, RbConfig.ruby, "extconf.rb")
        output << out1 << err1
        next false unless st1.success?

        out2, err2, st2 = Open3.capture3(env, "make")
        output << out2 << err2
        next false unless st2.success?

        # RubyGems runs `make install` after `make`; do the same so the .so
        # lands in lib/ where `require` will find it.
        out3, err3, st3 = Open3.capture3(env, "make", "install", "RUBYARCHDIR=#{lib_dir}")
        output << out3 << err3
        st3.success?
      end
      [!!ok, output.strip]
    end

    def run_load(lib_dir, name)
      script = "require #{name.inspect}; print #{const_name(name)}.add(2, 3)"
      out, status = Open3.capture2e(RbConfig.ruby, "-I#{lib_dir}", "-e", script)

      if status.success? && out.strip == "5"
        [true, "add(2, 3) == 5"]
      else
        [false, "loading the built extension failed:\n#{indent(out)}"]
      end
    end

    def const_name(snake)
      snake.split("_").map { |part| part[0].upcase + part[1..] }.join
    end

    # --- toolchain discovery -------------------------------------------------

    def detect_gdc
      explicit = ENV["GDC"]
      return File.expand_path(explicit) if explicit && !explicit.empty? && which(explicit)

      candidates = GDC_CANDIDATES.dup
      candidates.unshift(File.basename(explicit)) if explicit && !explicit.empty?
      candidates.uniq.each do |candidate|
        path = which(candidate)
        return path if path
      end

      nil
    end

    def which(binary)
      return binary if binary.include?("/") && File.executable?(binary)

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        path = File.join(dir, binary)
        return path if File.executable?(path) && !File.directory?(path)
      end
      nil
    end

    def gdc_version(binary)
      out = IO.popen([binary, "--version"], err: [:child, :out], &:read)
      # "gdc-14 (Ubuntu 14.2.0-4ubuntu2~24.04.1) 14.2.0" -> 14.2.0 (the GDC
      # release; the Ubuntu build suffix differs by distro).
      out[/\b(\d+\.\d+\.\d+)\b/, 1] || out[/\b(\d+\.\d+)\b/, 1]
    rescue SystemCallError
      nil
    end

    # --- reporting -----------------------------------------------------------

    def report
      @out.puts
      failed = @checks.any? { |c| c.status == FAIL }
      warned = @checks.any? { |c| c.status == WARN }

      @checks.each do |check|
        @out.puts "#{marker(check.status)} #{check.label}#{": #{check.detail}" if check.detail}"
        @out.puts "      → #{check.fix}" if check.fix
      end

      @out.puts
      if failed
        @out.puts "Not ready to build. Fix the items marked #{marker(FAIL)} above."
        1
      elsif warned
        @out.puts "Usable, with warnings — see #{marker(WARN)} items above."
        0
      else
        @out.puts "All good. Try:  rudy4 init fast_math && cd fast_math && rake test"
        0
      end
    end

    def marker(status)
      case status
      when PASS then "[ ok ]"
      when WARN then "[warn]"
      else           "[fail]"
      end
    end

    def indent(text, spaces = 8)
      text.to_s.lines.map { |line| " " * spaces + line }.join.rstrip
    end
  end
end
