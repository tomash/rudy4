# frozen_string_literal: true

require_relative "rudy4/error"
require_relative "rudy4/version"
require_relative "rudy4/vendor"
require_relative "rudy4/templates"
require_relative "rudy4/generator"
require_relative "rudy4/doctor"
require_relative "rudy4/cli"

# rudy4 — write Ruby native extensions in D.
#
# This file is the library half of the `rudy4` gem. The command-line half lives
# in `bin/rudy4`, which delegates to Rudy4::CLI.
module Rudy4
end
