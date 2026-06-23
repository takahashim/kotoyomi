# frozen_string_literal: true

# Loaded first by kotoyomi/cli.rb so it establishes the Kotoyomi::CLI namespace
# (class) that the other build-tool files reopen.
module Kotoyomi
  class CLI
    VERSION = "0.1.0"
  end
end
