MRuby::Gem::Specification.new("mruby-wasm-js") do |spec|
  spec.license = "MIT"
  spec.author = "kotoyomi authors"
  spec.summary = "mruby on WebAssembly — JS-host edition (createVM + JS interop)"

  # Implicit dependencies pulled into use by this gem:
  #   mruby-compiler  — src/js.c uses mrb_load_string (parser)
  #   mruby-fiber     — mrblib/js.rb's Value#await uses Fiber.yield/resume
  #   mruby-method    — Value#method_missing dispatch on a BasicObject subclass
  spec.add_dependency 'mruby-compiler', core: 'mruby-compiler'
  spec.add_dependency 'mruby-fiber',    core: 'mruby-fiber'
  spec.add_dependency 'mruby-method',   core: 'mruby-method'
end
