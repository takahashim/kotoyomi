# mruby-js-bridge

Minimal mruby ↔ JavaScript bridge for WASM hosts. Lets Ruby code running
in an mruby VM compiled to WebAssembly call into the JS host (browser,
Node, etc.) and vice versa, with a `ruby.wasm`-compatible feel
(`JSBridge.global[:document][:title] = "hello"`).

## Layout

```
mruby-js-bridge/
├── mrbgem.rake               # gem spec
├── README.md                 # this file
├── src/js_bridge.c           # C primitives (compiled into wasm)
├── mrblib/js_bridge.rb       # JSBridge module + Value class (compiled into wasm)
├── js/adapter.js             # JS-side host implementation of WASM imports
└── wasm_spec/                # Self-contained tests (need a JS host to run)
    ├── spec_helper.rb        # Spec micro-framework
    ├── runner.mjs            # Node test runner
    └── test_*.rb             # 9 test files, ~91 tests
```

The directory is `wasm_spec/` rather than `test/` to avoid mruby-test's
auto-discovery (`Dir.glob("#{dir}/test/*.rb")`) — the tests assume a JS
host (browser/Node), so they cannot run inside the standard mrbtest
binary.

## Using the gem

### 1. Add it to your build_config

```ruby
MRuby::CrossBuild.new("wasi") do |conf|
  conf.toolchain :clang
  # ... your wasi-sdk setup ...
  conf.gembox "default-no-stdio"
  conf.gem core: "mruby-method"   # required (method_missing dispatch)
  conf.gem core: "mruby-fiber"    # required (Value#await uses Fiber.yield)
  conf.gem core: "mruby-compiler" # required if you want runtime mrb_load_string
  conf.gem File.expand_path("path/to/mruby-js-bridge")
end
```

The gem's C side declares WASM imports under the module name `js_bridge`
(e.g. `js_bridge.js_eval`, `js_bridge.js_call`). Your linker must allow
these undefined symbols:

```
-Wl,--allow-undefined -Wl,--export=js_bridge_invoke_proc -Wl,--export=js_bridge_eval_handle
```

### 2. Boot from the JS host

```js
import { boot, evalRuby } from "<path-to-gem>/js/adapter.js";

const instance = await boot("/path/to/mruby.wasm");
evalRuby("puts JSBridge.global[:navigator][:userAgent].to_s");
```

`boot(wasmUrl)` instantiates the wasm with all required imports
(`js_bridge.*` for the bridge, `wasi_snapshot_preview1.*` for `puts`
etc.) and runs `_start`. After that, `evalRuby(source)` parses + runs
Ruby source on the live VM. Each call is auto-wrapped in a Fiber so
`Value#await` works at top level.

The adapter exports `debug` (toggle `debug.trace = true` to see handle
release / callback dispatch) and `alloc/get/release` (low-level handle
table — usually you don't need these).

### 3. Dispatch from Ruby

```ruby
JS = JSBridge

doc = JS.global[:document]                  # property access
doc.title = "hello"                         # method_missing → setter
doc.getElementById("audio")                 # method_missing → JS call

button.on(:click) { |ev| puts ev[:type].to_s }   # block as callback
JS.global[:Promise].resolve(42).then { |v| ... } # JS Promise
JS.global[:Promise].resolve(42).await            # blocking await (Fiber-based)
JS.global[:Date].new(2026, 4, 8)            # JS constructor
```

See `mrblib/js_bridge.rb` for the full surface (`==`, `typeof`,
`instanceof?`, `to_a`, `each`, `to_proc`, `inspect`, ...).

## Running the spec

The spec suite requires a JS host. From within this gem directory:

```bash
node wasm_spec/runner.mjs
```

By default it looks for `mruby.wasm` at `../../../host/mruby.wasm`
(matches the spike's layout where the build output lives in
`spike/host/`). To point at any other location, set the env var:

```bash
MRUBY_JS_BRIDGE_WASM=/abs/path/to/your/mruby.wasm \
  node wasm_spec/runner.mjs
```

Expected: `91/91 tests pass (127 assertions)`. Exit code 0 on success,
1 on any failure.

## Dependencies

| Gem | Why |
|---|---|
| `mruby-method` | enables `method_missing` dispatch |
| `mruby-fiber` | required for `Value#await` (Fiber.yield/resume) |
| `mruby-compiler` | required for `evalRuby` (runtime `mrb_load_string`) |

The default-no-stdio gembox + the three above is sufficient. Avoid
`mruby-regexp` — its mrblib redefines `String#split` and falls back to
`super`, which collides with the C-level `mrb_str_split_m` that core
already provides.

## License

MIT (see `mrbgem.rake`).
