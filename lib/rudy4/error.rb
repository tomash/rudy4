# frozen_string_literal: true

module Rudy4
  # Base class for the errors this gem reports to the user as a one-line
  # message plus an exit status, rather than a backtrace.
  class Error < StandardError; end

  # A command-line usage mistake (unknown option, too many arguments).
  class UsageError < Error; end
end
