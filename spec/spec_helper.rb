$LOAD_PATH.unshift File.expand_path("../cli/lib", __dir__)

require "kotoyomi/cli"
require "rspec"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.syntax = :expect
  end

  config.mock_with :rspec do |mocks|
    mocks.syntax = :expect
  end
end
