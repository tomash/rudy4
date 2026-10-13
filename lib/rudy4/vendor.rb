# frozen_string_literal: true

module Rudy4
  # The vendored copy of the rudy4 D library.
  #
  # rudy4 is consumed as *source* (`src/rudy/**/*.d`), not as an installed
  # binary. For a scaffolded project to build without a rudy4 checkout, this
  # gem ships that source tree under `vendor/` and copies it into the generated
  # project. `scripts/vendor_sync.sh` keeps it in sync with `src/rudy/` (CI
  # fails if the two drift).
  module Vendor
    module_function

    # Absolute path to the gem's `vendor/` directory. This is what goes on the
    # GDC include path: it is the parent of the `rudy/` module directory, so
    # `import rudy.bind.value;` resolves.
    def root
      File.expand_path("../../vendor", __dir__)
    end

    # Absolute path to the vendored `rudy/` module directory itself.
    def rudy_dir
      File.join(root, "rudy")
    end

    # Every vendored D source, sorted (stable order keeps build lines tidy).
    def d_sources
      Dir.glob(File.join(rudy_dir, "**", "*.d")).sort
    end

    # True when the vendored library looks complete.
    def present?
      File.file?(File.join(rudy_dir, "defs.d"))
    end
  end
end
