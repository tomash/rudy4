# frozen_string_literal: true

# Gem-level tests for the `rudy4` command: the scaffolder, the doctor, and the
# vendor refresh. Plain Ruby — no test framework, run it with:
#
#   ruby -Ilib test/rudy4_test.rb            # scaffolding + CLI (fast)
#   RUDY4_FULL=1 ruby -Ilib test/rudy4_test.rb   # + real GDC build (slow)
#
# The full build test is what CI runs: it scaffolds a project from the gem and
# drives `rake test` inside it, which is exactly the path a new user takes.

require "fileutils"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"

require "rudy4"

$checks = 0
$failures = []

def assert(cond, msg)
  $checks += 1
  return if cond

  $failures << msg
  puts "  FAIL: #{msg}"
end

def assert_equal(expected, actual, msg)
  assert(expected == actual, "#{msg} (expected #{expected.inspect}, got #{actual.inspect})")
end

def section(name)
  puts "\n== #{name}"
end

def run_cli(*argv)
  out = StringIO.new
  err = StringIO.new
  status = Rudy4::CLI.new(argv, out: out, err: err).run
  [status, out.string, err.string]
end

RUBY = RbConfig.ruby

# ---------------------------------------------------------------------------
section "CLI: version and help"

status, out, = run_cli("--version")
assert_equal 0, status, "--version exit status"
assert_equal Rudy4::VERSION, out.strip, "--version prints the version"

status, out, = run_cli("help")
assert_equal 0, status, "help exit status"
assert(out.include?("rudy4 init NAME"), "help documents init")
assert(out.include?("rudy4 doctor"), "help documents doctor")
assert(out.include?("rake compile"), "help shows the getting-started loop")

status, out, = run_cli(nil)
assert_equal 0, status, "bare invocation prints usage and exits 0"
assert(out.include?("Usage:"), "bare invocation prints usage")

status, _out, err = run_cli("frobnicate")
assert_equal Rudy4::CLI::EXIT_USAGE, status, "unknown command is a usage error"
assert(err.include?("unknown command"), "unknown command is reported")

status, _out, err = run_cli("init", "whatever", "--quick")
assert_equal Rudy4::CLI::EXIT_USAGE, status, "--quick is rejected for init"
assert(err.include?("not valid"), "invalid option is reported")

# ---------------------------------------------------------------------------
section "init: scaffold contents"

Dir.mktmpdir("rudy4-gem-test-") do |tmp|
  status, out, err = run_cli("init", "fast_math", "-h")
  assert_equal 0, status, "init -h prints usage"

  status, out, err = run_cli("init", "fast_math")
  assert_equal 0, status, "init exits 0 (err: #{err})"

  root = File.join(tmp, "fast_math")

  # The generator ran in Dir.pwd, so move it into the tmpdir to keep $PWD clean.
  # (CLI uses Dir.pwd by design, so we exercise it there and clean up after.)
  expected = [
    "fast_math.gemspec",
    "Rakefile",
    "README.md",
    ".gitignore",
    "lib/fast_math.rb",
    "lib/fast_math/version.rb",
    "ext/fast_math/fast_math.d",
    "ext/fast_math/extconf.rb",
    "ext/fast_math/rudy/defs.d",
    "ext/fast_math/rudy/bind/value.d",
    "ext/fast_math/rudy/convert.d",
    "ext/fast_math/rudy/args.d",
    "ext/fast_math/rudy/objproto.d",
    "ext/fast_math/rudy/typeddata.d",
    "test/fast_math_test.rb",
  ]
  expected.each do |rel|
    assert(File.file?(File.join("fast_math", rel)), "generated #{rel}")
  end

  assert(out.include?("Created fast_math/"), "init reports what it created")
  assert(out.include?("rake compile"), "init prints the next steps")

  # No leftover template placeholders anywhere.
  Dir.glob("fast_math/**/*").select { |f| File.file?(f) }.each do |file|
    body = File.read(file)
    %w[PROJECT_NAME PROJECT_CONST RUBY_REQ AUTHOR EMAIL].each do |token|
      assert(!body.include?(token), "#{file} has no unresolved #{token} placeholder")
    end
  end

  # The extension name must be spliced consistently: Init_<name>_ext, module,
  # gem name, and the artifact name are all the same project.
  d_source = File.read("fast_math/ext/fast_math/fast_math.d")
  assert(d_source.include?('pragma(mangle, "Init_fast_math_ext")'), "Init_ entry point named after the project")
  assert(d_source.include?('module fast_math;'), "D module named after the project")
  assert(d_source.include?('rb_define_module("FastMath")'), "Ruby module is the camelized name")
  assert(d_source.include?('def!("FastMath", add)'), "def! targets the Ruby module")

  extconf = File.read("fast_math/ext/fast_math/extconf.rb")
  assert(extconf.include?("TARGET = fast_math_ext."), "artifact is <name>_ext, not <name>")
  assert(extconf.include?('RUDY_SRC = File.join(HERE, "rudy")'),
         "extconf uses the vendored rudy sources, not a checkout path")
  assert(!extconf.include?("RUDY4_ROOT"), "extconf does not need RUDY4_ROOT")

  gemspec = File.read("fast_math/fast_math.gemspec")
  assert(gemspec.include?('spec.extensions = ["ext/fast_math/extconf.rb"]'),
         "gemspec declares the D extension")

  lib_rb = File.read("fast_math/lib/fast_math.rb")
  assert(lib_rb.include?('require "fast_math_ext"'), "lib requires the _ext artifact")

  FileUtils.rm_rf("fast_math")

  # -------------------------------------------------------------------------
  section "init: argument validation"

  status, _out, err = run_cli("init")
  assert_equal Rudy4::CLI::EXIT_USAGE, status, "init without a name is a usage error"
  assert(err.include?("usage: rudy4 init NAME"), "missing name shows usage")

  status, _out, err = run_cli("init", "fast-math")
  assert_equal Rudy4::CLI::EXIT_ERROR, status, "hyphenated name is rejected"
  assert(err.include?("snake_case"), "hyphenated name explains the rule")

  status, _out, err = run_cli("init", "FastMath")
  assert_equal Rudy4::CLI::EXIT_ERROR, status, "capitalized name is rejected"

  status, _out, err = run_cli("init", "ruby")
  assert_equal Rudy4::CLI::EXIT_ERROR, status, "reserved name is rejected"
  assert(err.include?("reserved"), "reserved name explains why")

  status, _out, err = run_cli("init", "fast_math", "extra")
  assert_equal Rudy4::CLI::EXIT_USAGE, status, "extra arguments are rejected"

  # -------------------------------------------------------------------------
  section "init: existing directory handling"

  Dir.mktmpdir("rudy4-existing-") do |dir|
    FileUtils.mkdir_p(File.join(dir, "taken"))
    File.write(File.join(dir, "taken", "precious.txt"), "do not clobber")

    generator = Rudy4::Generator.new("taken", parent_dir: dir, out: StringIO.new)
    begin
      generator.call
      assert(false, "refuses to overwrite a non-empty directory")
    rescue Rudy4::Error => e
      assert(e.message.include?("already exists"), "existing directory is reported")
      assert(e.message.include?("--force"), "the error suggests --force")
    end

    assert_equal "do not clobber", File.read(File.join(dir, "taken", "precious.txt")),
                 "existing files are untouched"

    forced = Rudy4::Generator.new("taken", parent_dir: dir, force: true, out: StringIO.new)
    forced.call
    assert(File.file?(File.join(dir, "taken", "taken.gemspec")), "--force writes into the directory")
    assert(File.file?(File.join(dir, "taken", "precious.txt")), "--force does not delete existing files")
  end

  # -------------------------------------------------------------------------
  section "vendor: refresh an existing project"

  status, _out, err = run_cli("init", "vendored_app")
  assert_equal 0, status, "scaffold a project for the vendor test (err: #{err})"

  ext_dir = File.join("vendored_app", "ext", "vendored_app")
  sentinel = File.join(ext_dir, "rudy", "defs.d")
  File.write(sentinel, "// stale, hand-mangled copy")
  File.write(File.join(ext_dir, "vendored_app.d"), "// user code — must not be touched")

  Dir.chdir(ext_dir) do
    status, out, err = run_cli("vendor")
    assert_equal 0, status, "vendor exits 0 (err: #{err})"
    assert(out.include?("Refreshed"), "vendor reports what it refreshed")
  end

  assert(!File.read(sentinel).include?("stale"), "vendor overwrites the stale vendored source")
  assert_equal Rudy4::Vendor.d_sources.length,
               Dir.glob(File.join(ext_dir, "rudy", "**", "*.d")).length,
               "vendor restores every vendored source"
  assert_equal "// user code — must not be touched",
               File.read(File.join(ext_dir, "vendored_app.d")),
               "vendor leaves user code alone"

  FileUtils.rm_rf("vendored_app")

  # -------------------------------------------------------------------------
  section "doctor: quick checks"

  Dir.mktmpdir("rudy4-doctor-") do |dir|
    Dir.chdir(dir) do
      out = StringIO.new
      status = Rudy4::Doctor.new(quick: true, out: out).call
      text = out.string

      assert(text.include?("rudy4 doctor"), "doctor prints a header")
      assert(text.include?("ruby headers"), "doctor checks ruby headers")
      assert(text.include?("shared libruby"), "doctor checks the shared library")
      assert(text.include?("gdc (D compiler)"), "doctor checks GDC")
      assert(text.include?("vendored rudy4 sources"), "doctor checks the vendored sources")
      assert(!text.include?("build smoke test"), "--quick skips the build probe")

      gdc_ok = !text.include?("[fail] gdc")
      headers_ok = !text.include?("[fail] ruby headers")
      if gdc_ok && headers_ok
        assert_equal 0, status, "doctor exits 0 on a healthy toolchain"
      else
        assert_equal 1, status, "doctor exits 1 when the toolchain is missing"
      end
    end
  end
end

# ---------------------------------------------------------------------------
if ENV["RUDY4_FULL"] == "1"
  section "end-to-end: scaffold, GDC build, generated test suite (slow)"

  Dir.mktmpdir("rudy4-e2e-") do |dir|
    Dir.chdir(dir) do
      status, _out, err = run_cli("init", "fast_math")
      assert_equal 0, status, "init for the e2e build (err: #{err})"

      # The exact path a new user runs.
      out, build_status = Open3.capture2e({ "GDC" => ENV["GDC"] || "gdc-14" },
                                          "rake", "test",
                                          chdir: File.join(dir, "fast_math"))
      puts out
      assert(build_status.success?, "rake test succeeds in the generated project")

      lib = File.join(dir, "fast_math", "lib", "fast_math_ext.#{RbConfig::CONFIG['DLEXT']}")
      assert(File.file?(lib), "rake compile installs the artifact into lib/")

      probe, probe_status = Open3.capture2e(
        RUBY, "-I#{File.dirname(lib)}", "-e",
        'require "fast_math"; print FastMath.squares(3).inspect',
      )
      assert_equal "[0.0, 1.0, 4.0]", probe.strip, "the built extension is loadable and correct"\
        if probe_status.success?
      assert(probe_status.success?, "loading the built extension succeeds")

      # `rake` + no build residue tracked by the gem's own .gitignore.
      gitignore = File.read(File.join(dir, "fast_math", ".gitignore"))
      assert(gitignore.include?("/lib/*.so"), ".gitignore covers built artifacts")

      # And the doctor, end to end, inside the generated project.
      out = StringIO.new
      status = Rudy4::Doctor.new(out: out).call
      puts out.string
      assert_equal 0, status, "doctor reports a healthy setup inside a generated project"
    end
  end
end

# ---------------------------------------------------------------------------
puts
if $failures.empty?
  puts "rudy4 gem tests: #{$checks} assertions OK"
  exit 0
else
  puts "rudy4 gem tests: #{$checks} assertions, #{$failures.length} FAILED"
  $failures.each { |f| puts "  - #{f}" }
  exit 1
end
