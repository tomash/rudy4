# frozen_string_literal: true

module Rudy4
  # File bodies for a scaffolded D-backed extension gem.
  #
  # Templates are kept as single-quoted heredocs so nothing is interpolated
  # here, and placeholders are substituted in one pass by `render`. The
  # placeholder words are deliberately written as single tokens
  # (PROJECT_NAME) so they survive copy/paste and are obvious in the source.
  module Templates
    GEMSPEC = <<~'RUBY'
      # frozen_string_literal: true

      require_relative "lib/PROJECT_NAME/version"

      Gem::Specification.new do |spec|
        spec.name    = "PROJECT_NAME"
        spec.version = PROJECT_CONST::VERSION
        spec.authors = ["AUTHOR"]
        spec.email   = ["EMAIL"]

        spec.summary     = "A D-backed Ruby native extension"
        spec.description = <<~DESC
          The native half of this gem is written in D and compiled by GDC
          through the rudy4 library. Edit ext/PROJECT_NAME/PROJECT_NAME.d,
          run `rake compile`, and call the result from Ruby.
        DESC
        spec.homepage = "https://github.com/tomash/rudy4"
        spec.license  = "MIT"

        spec.required_ruby_version = ">= RUBY_REQ"

        spec.files = Dir[
          "lib/**/*.rb",
          "ext/**/*.d",
          "ext/**/*.rb",
          "README.md",
        ]
        spec.require_paths = ["lib"]

        # RubyGems runs extconf.rb (which writes a GDC Makefile) and then
        # `make install`, exactly as it would for a C extension.
        spec.extensions = ["ext/PROJECT_NAME/extconf.rb"]

        spec.metadata["rubygems_mfa_required"] = "true"
      end
    RUBY

    VERSION_RB = <<~'RUBY'
      # frozen_string_literal: true

      module PROJECT_CONST
        VERSION = "0.1.0"
      end
    RUBY

    LIB_RB = <<~'RUBY'
      # lib/PROJECT_NAME.rb
      #
      # The Ruby half of the gem: load the compiled native extension, and add
      # plain-Ruby conveniences on top of it if you want. The native code
      # lives in ext/PROJECT_NAME/PROJECT_NAME.d.

      require_relative "PROJECT_NAME/version"

      # The native artifact is suffixed `_ext` so it does not shadow this
      # file on the load path. `rake compile` (or `gem install`) installs it
      # next to this one.
      begin
        require "PROJECT_NAME_ext"
      rescue LoadError => e
        raise LoadError, <<~MSG
          Could not load the native PROJECT_NAME extension (#{e.message}).

          Build it first:
            rake compile

          If that fails, run `rudy4 doctor` to check your Ruby + GDC setup.
        MSG
      end

      module PROJECT_CONST
        # Plain-Ruby helpers go here; `add`, `greet`, `is_even` and
        # `scale_all` come from D. Anything you write here is ordinary Ruby.
      end
    RUBY

    D_SOURCE = <<~'D'
      /// PROJECT_NAME.d — the native half of the PROJECT_NAME gem.
      ///
      /// This is YOUR code. Everything else under ext/PROJECT_NAME/ is the
      /// vendored rudy4 library (rudy/) plus the build glue (extconf.rb).
      ///
      /// `def!` registers a D function as a Ruby method and converts
      /// arguments and return values for you. Declare plain D types:
      ///
      ///   long      <->  Integer          double  <->  Float
      ///   string    <->  String           bool    <->  true / false
      ///   double[]  <->  Array of Float   (as a RETURN type)
      ///   Rest      <->  Ruby *args       KwArgs   <->  Ruby **kwargs
      ///
      /// The edit loop:
      ///
      ///   1. change a function below
      ///   2. run `rake compile`  (GDC builds the .so)
      ///   3. run `rake test`
      ///
      /// If you want a raw Ruby VALUE instead of a converted argument,
      /// declare the parameter (or return type) as Raw!VALUE.

      module PROJECT_NAME;

      import rudy.bind.value;
      import rudy.convert;
      import rudy.defs;
      import rudy.args;

      import core.runtime : rt_init;

      // ---------------------------------------------------------------------
      // Your functions. Change these.
      // ---------------------------------------------------------------------

      /// PROJECT_CONST.add(2, 3)  =>  5
      long add(long a, long b)
      {
          return a + b;
      }

      /// PROJECT_CONST.greet("world")  =>  "hello, world!"
      /// Strings are copied into D (idup) before your code sees them.
      string greet(string name)
      {
          return "hello, " ~ name ~ "!";
      }

      /// PROJECT_CONST.is_even(4)  =>  true
      /// A D bool comes back as Ruby true / false, never a raw 0/1.
      bool is_even(long n)
      {
          return (n % 2) == 0;
      }

      /// A parameter with a D default value becomes an OPTIONAL Ruby
      /// argument: PROJECT_CONST.shout("hi") and PROJECT_CONST.shout("hi", 2)
      /// both work.
      string shout(string word, long times = 3)
      {
          string out_;
          foreach (_; 0 .. times)
              out_ ~= word ~ "!";
          return out_;
      }

      /// PROJECT_CONST.sum_all(1, 2, 3)  =>  6
      /// `Rest` collects Ruby's trailing arguments (*args). Values arrive as
      /// raw VALUEs; convert each with d_type!T.
      long sum_all(Rest rest)
      {
          long total = 0;
          foreach (v; rest)
              total += d_type!long(v);
          return total;
      }

      /// PROJECT_CONST.squares(3)  =>  [0.0, 1.0, 4.0]
      /// A D dynamic array RETURN becomes a Ruby Array, element by element.
      double[] squares(long n)
      {
          double[] out_;
          out_.reserve(n);
          foreach (i; 0 .. n)
              out_ ~= cast(double) i * cast(double) i;
          return out_;
      }

      // ---------------------------------------------------------------------
      // Optional next steps (delete when you have your own code):
      //
      // * Named arguments: `string tag(KwArgs kw)` plus
      //   `kw.get!string("label", "default")` — Ruby calls it as
      //   PROJECT_CONST.tag(label: "x"). See README.md.
      //
      // * A D struct as a real Ruby object (allocate / dup / == / hash /
      //   inspect / freeze-aware mutators). See README.md, "Exposing a D
      //   struct", or examples/hello_gem in the rudy4 repo.
      //
      // * Long-running work that must not block other Ruby threads: run it
      //   under rb_thread_call_without_gvl (README.md, "Long-running work").
      // ---------------------------------------------------------------------

      // ---------------------------------------------------------------------
      // Entry point — Ruby calls this once when the extension is required.
      // Add a `def!(...)` line here for every function Ruby should see.
      // ---------------------------------------------------------------------

      pragma(mangle, "Init_PROJECT_NAME_ext")
      extern (C) void Init_PROJECT_NAME_ext()
      {
          rt_init();

          rb_define_module("PROJECT_CONST");

          def!("PROJECT_CONST", add);
          def!("PROJECT_CONST", greet);
          def!("PROJECT_CONST", is_even);
          def!("PROJECT_CONST", shout);
          def!("PROJECT_CONST", sum_all);
          def!("PROJECT_CONST", squares);
      }
    D

    EXTCONF_RB = <<~'RUBY'
      # ext/PROJECT_NAME/extconf.rb
      #
      # A stand-in for mkmf, for an extension whose compiler is GDC (D), not a
      # C compiler. It writes a Makefile that compiles
      #
      #   ext/PROJECT_NAME/PROJECT_NAME.d    (your code)
      # + ext/PROJECT_NAME/rudy/**/*.d       (the vendored rudy4 library,
      #                                       shipped here so the extension
      #                                       builds with no external checkout)
      #
      # into PROJECT_NAME_ext.so, and exposes the `install` target RubyGems
      # calls.

      require "rbconfig"

      HERE     = __dir__
      RUDY_SRC = File.join(HERE, "rudy")

      unless File.file?(File.join(RUDY_SRC, "defs.d"))
        abort <<~MSG
          The vendored rudy4 sources are missing from #{RUDY_SRC}.
          Re-run `rudy4 init PROJECT_NAME` to regenerate this project.
        MSG
      end

      RUDY_D_SOURCES = Dir.glob(File.join(RUDY_SRC, "**", "*.d")).sort

      # RubyGems sets RUBYARCHDIR for `gem install`; a bare
      # `ruby extconf.rb && make install` defaults to the gem's lib/, so the
      # extension can be required in place.
      RUBYARCHDIR = ENV["RUBYARCHDIR"] || File.expand_path("../../lib", HERE)

      hdr     = RbConfig::CONFIG["rubyhdrdir"]
      archhdr = RbConfig::CONFIG["rubyarchhdrdir"]
      libarg  = RbConfig::CONFIG["LIBRUBYARG_SHARED"]
      libdir  = RbConfig::CONFIG["libdir"]
      dllib   = RbConfig::CONFIG["DLEXT"] # "so"

      gdc = ENV["GDC"] || "gdc-14"

      File.write(File.join(HERE, "Makefile"), <<~MAKE)
        # Generated by extconf.rb — do not edit; re-run `ruby extconf.rb`.
        GDC         = #{gdc}
        RUBYHDR     = #{hdr}
        RUBYARCHHDR = #{archhdr}
        LIBRUBYARG  = #{libarg}
        LIBRUBY_DIR = #{libdir}
        RUBYARCHDIR = #{RUBYARCHDIR}

        DFLAGS = -fPIC -I#{HERE} -I$(RUBYHDR) -I$(RUBYARCHHDR) \\
                 -fpreview=dip1008 -Wno-deprecated

        RUDY_SOURCES = #{RUDY_D_SOURCES.join(" ")}

        TARGET = PROJECT_NAME_ext.#{dllib}

        all: $(TARGET)

        $(TARGET): PROJECT_NAME.d $(RUDY_SOURCES)
        \t$(GDC) -shared -o $@ $(DFLAGS) $(RUDY_SOURCES) PROJECT_NAME.d \\
        \t  -L$(LIBRUBY_DIR) $(LIBRUBYARG) -lm

        install: $(TARGET)
        \tmkdir -p $(RUBYARCHDIR)
        \tcp $(TARGET) $(RUBYARCHDIR)/

        clean:
        \trm -f $(TARGET)
      MAKE
    RUBY

    TEST_RB = <<~'RUBY'
      # frozen_string_literal: true

      # Plain-Ruby test — no test framework needed.
      # Run:  rake test    (or: ruby -Ilib test/PROJECT_NAME_test.rb)

      require "PROJECT_NAME"

      checks = 0
      assert = lambda do |cond, msg|
        checks += 1
        raise "FAIL: #{msg}" unless cond
      end

      assert.(PROJECT_CONST.add(2, 3) == 5, "add")
      assert.(PROJECT_CONST.greet("world") == "hello, world!", "greet")
      assert.(PROJECT_CONST.is_even(4) == true, "is_even(4)")
      assert.(PROJECT_CONST.is_even(5) == false, "is_even(5)")
      assert.(PROJECT_CONST.shout("hi", 2) == "hi!hi!", "optional argument")
      assert.(PROJECT_CONST.sum_all(1, 2, 3) == 6, "rest arguments (*args)")
      assert.(PROJECT_CONST.squares(3) == [0.0, 1.0, 4.0], "array return")

      puts "#{checks} assertions OK"
    RUBY

    RAKEFILE = <<~'RUBY'
      # frozen_string_literal: true

      require "rake/clean"
      require "rbconfig"

      ROOT     = __dir__
      EXT_DIR  = File.join(ROOT, "ext", "PROJECT_NAME")
      DLEXT    = RbConfig::CONFIG["DLEXT"]
      TARGET   = File.join(EXT_DIR, "PROJECT_NAME_ext.#{DLEXT}")
      LIB_SO   = File.join(ROOT, "lib", "PROJECT_NAME_ext.#{DLEXT}")

      CLEAN.include(File.join(EXT_DIR, "Makefile"), TARGET, LIB_SO)
      CLOBBER.include(File.join(EXT_DIR, "*.o"))

      # The Ruby running this Rakefile — not whatever `ruby` is on PATH.
      RUBY = RbConfig.ruby

      desc "Compile the D native extension with GDC"
      task :compile do
        Dir.chdir(EXT_DIR) do
          sh RUBY, "extconf.rb"
          sh "make"
        end
        cp TARGET, LIB_SO
        puts "built #{LIB_SO}"
      end

      desc "Compile, then run the test suite"
      task :test => :compile do
        sh RUBY, "-Ilib", "test/PROJECT_NAME_test.rb"
      end

      task :default => :test
    RUBY

    GITIGNORE = <<~'TEXT'
      /lib/*.so
      /lib/*.bundle
      /ext/PROJECT_NAME/Makefile
      /ext/PROJECT_NAME/*.so
      /ext/PROJECT_NAME/*.o
      /*.gem
      /tmp/
    TEXT

    README = <<~'TEXT'
      # PROJECT_NAME

      A Ruby native extension whose native half is written in **D** and
      compiled by **GDC** through [rudy4](https://github.com/tomash/rudy4).

      ## Quickstart

      ```sh
      rake compile                    # builds ext/PROJECT_NAME/PROJECT_NAME.d
      rake test                       # runs test/PROJECT_NAME_test.rb
      ruby -Ilib -e 'require "PROJECT_NAME"; p PROJECT_CONST.add(2, 3)'
      ```

      ## The edit loop

      1. Edit `ext/PROJECT_NAME/PROJECT_NAME.d` — that is the whole native
         side. `def!` turns a D function into a Ruby method and converts
         arguments and return values:

         ```d
         long add(long a, long b) { return a + b; }
         // ...
         def!("PROJECT_CONST", add);
         ```

         The generated file also shows optional arguments (D default values),
         Ruby `*args` (the `Rest` wrapper) and array returns — delete them
         once you have your own functions.

      2. `rake compile`
      3. `rake test`

      ## Layout

      ```
      PROJECT_NAME/
        PROJECT_NAME.gemspec
        Rakefile
        ext/PROJECT_NAME/
          PROJECT_NAME.d     <- your D code
          extconf.rb         <- writes the GDC Makefile (mkmf stand-in)
          rudy/              <- vendored rudy4 library (do not edit)
        lib/
          PROJECT_NAME.rb
          PROJECT_NAME/version.rb
        test/PROJECT_NAME_test.rb
      ```

      The `rudy/` tree is a copy of rudy4's D library, shipped inside the gem
      so the extension builds on its own — no rudy4 checkout, no
      `RUDY4_ROOT`. It is pinned to the rudy4 gem version this project was
      generated with; refresh it after upgrading rudy4 (the generator prints
      the exact command, or use `rudy4 vendor`).

      ## Using it from another project

      From the app that wants the extension:

      ```ruby
      # Gemfile
      gem "PROJECT_NAME", path: "../PROJECT_NAME"
      ```

      or, once built, load it by hand:

      ```sh
      ruby -I../PROJECT_NAME/lib -e 'require "PROJECT_NAME"'
      ```

      To publish it, `gem build PROJECT_NAME.gemspec` and push it like any
      other gem — RubyGems will compile the D source during install.

      ## Exposing a D struct

      When scalars are not enough, a D struct can become a first-class Ruby
      object:

      ```d
      struct Vec2 { double x, y; }

      mixin RudyTypedData!(Vec2, "PROJECT_NAME_vec2");
      mixin RudyObjectProtocol!(Vec2, "PROJECT_NAME_vec2",
                                null, null, null, vec2_inspect);
      ```

      and in `Init_...`:

      ```d
      VALUE c = rb_define_class("Vec2", rb_cObject);
      PROJECT_NAME_vec2_proto_install(c);
      ```

      That gives `Vec2` allocate / `dup` / `clone` / `==` / `eql?` / `hash` /
      `inspect`; add methods of your own with `rb_define_method`. See
      `examples/hello_gem/` in the rudy4 repo for a complete worked example
      (including a freeze-aware `[]=`).

      ## Long-running work

      A `def!`'d method holds the GVL, so a slow one blocks every other Ruby
      thread until it returns. For blocking I/O or long computation, wrap the
      work in `rb_thread_call_without_gvl` (bound by rudy4) and provide an
      unblock function so the call stays interruptible.

      ## When something goes wrong

      * `rudy4 doctor` — checks GDC, Ruby headers, and that a scaffolded
        extension compiles and loads.
      * `rake compile` fails immediately with "vendored rudy4 sources are
        missing" — regenerate the project with `rudy4 init`.
      * `LoadError: Could not load the native ... extension` — you have not
        compiled yet (`rake compile`).

      ## Requirements

      * Ruby RUBY_REQ+ with development headers (`ruby-dev` / `ruby-devel`)
      * GDC (the D compiler), version 13 or newer — currently tested with
        GDC 14
      * `make`
    TEXT

    def self.render(template, tokens)
      out = template.dup
      tokens.each { |key, value| out = out.gsub(key, value.to_s) }
      out
    end
  end
end
