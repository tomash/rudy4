# frozen_string_literal: true

require "fileutils"
require "rbconfig"

require_relative "error"
require_relative "templates"
require_relative "vendor"

module Rudy4
  # `rudy4 init NAME` — scaffold a self-contained D-backed extension gem.
  #
  # "Self-contained" is the point: the generated project vendors the rudy4 D
  # library under ext/NAME/rudy/, so it compiles with nothing but GDC + the
  # Ruby headers — no rudy4 checkout, no RUDY4_ROOT.
  class Generator
    Error = Rudy4::Error

    # A rubygems-legal name: lowercase, digits, underscores; must start with a
    # letter. We reject dots/hyphens on purpose — the extension name is spliced
    # into D identifiers and file names, where they would not survive.
    NAME_RE = /\A[a-z][a-z0-9_]*\z/

    # The names Ruby's own kernel/object namespace already owns well enough
    # that shadowing them would confuse rather than help a first project.
    RESERVED = %w[
      ruby rudy rudy4 object kernel basicobject module klass class
      string integer float array hash symbol range struct
    ].freeze

    attr_reader :name, :dir

    # @param name [String] the extension name (also the gem and directory name)
    # @param parent_dir [String] where to create `NAME/`
    # @param force [Boolean] write into an existing non-empty directory
    def initialize(name, parent_dir: Dir.pwd, force: false, out: $stdout)
      @name   = name.to_s
      @dir    = File.expand_path(File.join(parent_dir, @name))
      @force  = force
      @out    = out

      validate_name!
    end

    def call
      guard_target!

      unless Vendor.present?
        raise Error, <<~MSG
          The rudy4 gem's vendored D library is missing (#{Vendor.rudy_dir}).
          Reinstall the gem (`gem install rudy4`) — a scaffold without it
          could never compile.
        MSG
      end

      FileUtils.mkdir_p(@dir)
      written = []
      each_file { |relative, content| written << write_file(relative, content) }
      written += vendor_sources
      written.sort
    end

    def print_next_steps
      @out.puts <<~TEXT

        Created #{@name}/ — a Ruby extension gem whose native half is D.

        Next:
          cd #{@name}
          rake compile      # GDC builds ext/#{@name}/#{@name}.d
          rake test         # 7 assertions against the compiled extension

        Then edit ext/#{@name}/#{@name}.d and repeat `rake compile && rake test`.
        Stuck? Run `rudy4 doctor` from inside the project.
      TEXT
    end

    private

    def validate_name!
      raise Error, "Extension name is required." if @name.empty?

      unless @name.match?(NAME_RE)
        raise Error, <<~MSG
          "#{@name}" is not a usable extension name.
          Use `snake_case` — a lowercase letter, then lowercase letters,
          digits or underscores (e.g. `fast_math`). Dotted or hyphenated
          names do not survive being spliced into D identifiers.
        MSG
      end

      return unless RESERVED.include?(@name)

      raise Error, <<~MSG
        "#{@name}" is reserved by rudy4 or by Ruby itself; pick another name.
      MSG
    end

    def guard_target!
      return unless File.exist?(@dir)
      return if @force
      return if Dir.children(@dir).empty?

      raise Error, <<~MSG
        #{@dir} already exists and is not empty.
        Pick another name, or re-run with --force to write into it anyway.
      MSG
    end

    def ruby_req
      # Scaffold for the Ruby running the generator's major.minor. rudy4 tracks
      # the 4.x C API; claiming a looser requirement would be a lie.
      RbConfig::CONFIG["ruby_version"] || "4.0"
    end

    def tokens
      {
        "PROJECT_CONST" => camelize(@name),
        "PROJECT_NAME"  => @name,
        "RUBY_REQ"      => ruby_req,
        "AUTHOR"        => git_config("user.name") || "Your Name",
        "EMAIL"         => git_config("user.email") || "you@example.com",
      }
    end

    def camelize(snake)
      snake.split("_").map { |part| part[0].upcase + part[1..] }.join
    end

    def git_config(key)
      value = IO.popen(["git", "config", "--get", key], &:read).strip
      value.empty? ? nil : value
    rescue SystemCallError
      nil
    end

    def each_file
      yield "#{@name}.gemspec",                        Templates.render(Templates::GEMSPEC, tokens)
      yield "lib/#{@name}.rb",                         Templates.render(Templates::LIB_RB, tokens)
      yield "lib/#{@name}/version.rb",                 Templates.render(Templates::VERSION_RB, tokens)
      yield "ext/#{@name}/#{@name}.d",                 Templates.render(Templates::D_SOURCE, tokens)
      yield "ext/#{@name}/extconf.rb",                 Templates.render(Templates::EXTCONF_RB, tokens)
      yield "test/#{@name}_test.rb",                   Templates.render(Templates::TEST_RB, tokens)
      yield "Rakefile",                                Templates.render(Templates::RAKEFILE, tokens)
      yield "README.md",                               Templates.render(Templates::README, tokens)
      yield ".gitignore",                              Templates::GITIGNORE
    end

    def write_file(relative, content)
      path = File.join(@dir, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
      relative
    end

    # Copy the vendored rudy4 library in, preserving the `rudy/` module
    # directory so `import rudy.bind.value;` resolves at build time.
    def vendor_sources
      sources = Vendor.d_sources
      raise Error, "No vendored rudy4 D sources found in #{Vendor.rudy_dir}." if sources.empty?

      sources.map do |source|
        relative = File.join("ext", @name, "rudy",
                             source.delete_prefix("#{Vendor.rudy_dir}/"))
        path = File.join(@dir, relative)
        FileUtils.mkdir_p(File.dirname(path))
        FileUtils.cp(source, path)
        relative
      end
    end
  end
end
