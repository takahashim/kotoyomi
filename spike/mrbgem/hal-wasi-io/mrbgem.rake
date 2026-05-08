MRuby::Gem::Specification.new('hal-wasi-io') do |spec|
  spec.license = 'MIT'
  spec.author  = 'kotoyomi authors'
  spec.summary = 'WASI HAL for mruby-io (wasm32-wasip1)'

  # Pulls in mruby-io and registers as the IO HAL backend for it.
  # mruby-io's HAL auto-loader detects any sibling gem matching
  # /^hal-.*-io$/ and skips its hal-posix-io fallback, so listing
  # hal-wasi-io in the build_config is enough.
  spec.add_dependency 'mruby-io', core: 'mruby-io'
end
