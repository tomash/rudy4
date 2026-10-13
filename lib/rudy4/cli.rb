# frozen_string_literal: true

require "fileutils"

require_relative "error"
require_relative "version"
require_relative "vendor"
require_relative "generator"
require_relative "doctor"

module Rudy4
  # Command-line front end for the rudy4 gem.
  #
  #   rudy4 init NAME [--force]   scaffold a self-contained extension gem
  #   rudy4 doctor [--quick]      check the Ruby + GDC toolchain
  #   rudy4 vendor                refresh the vendored rudy4 sources in place
  #   rudy4 --version
  #   rudy4 help
  class CLI
    EXIT_OK    = 0
    EXIT_ERROR = 1
    EXIT_USAGE = 64

    def initialize(argv, out: $stdout, err: $stderr)
      @argv = argv.dup
      @out  = out
      @err  = err
    end

    def run
      command = @argv.shift

      case command
      when nil, "help", "-h", "--help" then usage; EXIT_OK
      when "--version", "-v", "version" then @out.puts Rudy4::VERSION; EXIT_OK
      when "init", "new"                then cmd_init
      when "doctor", "check"            then cmd_doctor
      when "vendor"                     then cmd_vendor
      else
        @err.puts "rudy4: unknown command #{command.inspect}"
        @err.puts
        usage(@err)
        EXIT_USAGE
      end
    rescue UsageError => e
      @err.puts "rudy4: #{e.message}"
      EXIT_USAGE
    rescue Error => e
      @err.puts "rudy4: #{e.message}"
      EXIT_ERROR
    end

    private

    # Minimal hand-rolled option parsing — the gem deliberately has no runtime
    # dependencies, so no OptionParser/Thor.
    def parse_options(args, allowed)
      opts = {}
      rest = []

      args.each do |arg|
        case arg
        when "--force"        then require_flag(allowed, "force"); opts[:force] = true
        when "--quick"        then require_flag(allowed, "quick"); opts[:quick] = true
        when "--help", "-h"   then require_flag(allowed, "help"); opts[:help] = true
        when /\A--/           then raise UsageError, "unknown option #{arg}"
        else rest << arg
        end
      end

      [opts, rest]
    end

    def require_flag(allowed, name)
      return if allowed.include?(name)

      raise UsageError, "option --#{name} is not valid for this command"
    end

    def cmd_init
      opts, rest = parse_options(@argv, %w[force help])
      if opts[:help]
        usage(@out)
        return EXIT_OK
      end

      name = rest.shift
      if name.nil? || name.empty?
        raise UsageError, "usage: rudy4 init NAME\n       e.g. rudy4 init fast_math"
      end

      unless rest.empty?
        raise UsageError, "rudy4 init takes a single NAME (got: #{([name] + rest).join(' ')})"
      end

      generator = Generator.new(name, force: opts[:force], out: @out)
      files = generator.call
      generator.print_next_steps

      @out.puts
      @out.puts "  #{files.length} files written."
      EXIT_OK
    end

    def cmd_doctor
      opts, rest = parse_options(@argv, %w[quick help])
      if opts[:help]
        usage(@out)
        return EXIT_OK
      end

      raise UsageError, "rudy4 doctor takes no arguments" unless rest.empty?

      Doctor.new(quick: opts[:quick], out: @out).call
    end

    # Refresh the vendored rudy4 sources inside an existing scaffolded project.
    # The copied-in library is pinned to the gem version it was generated with;
    # this re-syncs it after a rudy4 upgrade, without touching user code.
    def cmd_vendor
      opts, rest = parse_options(@argv, %w[help])
      if opts[:help]
        usage(@out)
        return EXIT_OK
      end

      raise UsageError, "rudy4 vendor takes no arguments" unless rest.empty?

      target = find_extension_dir
      unless target
        raise Error, <<~MSG
          No D extension module found from #{Dir.pwd} upward.
          Run this from the root of a rudy4-generated project (or one of its
          subdirectories) — expected something like ext/NAME/NAME.d.
        MSG
      end

      unless Vendor.present?
        raise Error, "The rudy4 gem's vendored sources are missing; reinstall the gem."
      end

      dest = File.join(target, "rudy")
      FileUtils.mkdir_p(dest)

      written = Vendor.d_sources.map do |source|
        relative = source.delete_prefix("#{Vendor.rudy_dir}/")
        path = File.join(dest, relative)
        FileUtils.mkdir_p(File.dirname(path))
        FileUtils.cp(source, path)
        relative
      end

      @out.puts "Refreshed #{written.length} vendored rudy4 sources in #{dest}"
      @out.puts "Refreshed from rudy4 gem v#{Rudy4::VERSION}. Review the rudy4 CHANGELOG for API"
      @out.puts "changes, then run `rake compile`."
      EXIT_OK
    end

    # Walk up from the current directory looking for an extension whose D source
    # matches the name of its own directory (the layout `rudy4 init` produces).
    def find_extension_dir
      dir = File.expand_path(Dir.pwd)

      loop do
        ext = File.join(dir, "ext")
        if File.directory?(ext)
          Dir.children(ext).sort.each do |entry|
            candidate = File.join(ext, entry)
            next unless File.directory?(candidate)
            return candidate if File.file?(File.join(candidate, "#{entry}.d"))
          end
        end

        parent = File.dirname(dir)
        break if parent == dir

        dir = parent
      end

      nil
    end

    def usage(io = @out)
      io.puts <<~TEXT
        rudy4 #{Rudy4::VERSION} — write Ruby native extensions in D

        Usage:
          rudy4 init NAME [--force]   Scaffold a self-contained extension gem
          rudy4 doctor [--quick]      Check the Ruby + GDC toolchain
          rudy4 vendor                Refresh the vendored rudy4 sources
          rudy4 --version
          rudy4 help

        Getting started:
          rudy4 init fast_math
          cd fast_math
          rake compile                # build the D extension with GDC
          rake test                   # run the generated test suite

        Then edit ext/fast_math/fast_math.d and repeat `rake compile && rake test`.
      TEXT
    end
  end
end
