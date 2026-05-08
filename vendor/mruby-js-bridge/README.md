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
├── js/index.js               # JS-side entry point (createVM factory + JSBridge core)
├── js/wasi-preview1.js       # bundled WASI preview1 implementation
├── js/_memory.js             # internal: shared TextDecoder/Encoder + memory helpers
├── js/debug.js               # global debug toggle
└── wasm_spec/                # Self-contained tests (need a JS host to run)
    ├── spec_helper.rb        # Spec micro-framework
    ├── runner.mjs            # Node test runner
    └── test_*.rb             # 13 test files, ~167 tests
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
  conf.gem core: "mruby-io"       # optional (File.read/open via WASI fs)
  conf.gem core: "mruby-time"     # optional (Time.now via WASI clock_time_get)
  conf.gem core: "mruby-random"   # optional (rand/Random via WASI random_get)
  conf.gem File.expand_path("path/to/mruby-js-bridge")
  # Optional sibling gems — Ruby surface for WASI primitives that mruby
  # core doesn't ship.
  conf.gem File.expand_path("path/to/mruby-wasi-dir")  # Dir.entries / mkdir / rmdir / exist?
  conf.gem File.expand_path("path/to/mruby-wasi-env")  # ENV[] / ENV[]= / each / keys / ...
end
```

The gem's C side declares WASM imports under the module name `js_bridge`
(e.g. `js_bridge.js_eval`, `js_bridge.js_call`). Your linker must allow
these undefined symbols:

```
-Wl,--allow-undefined -Wl,--export=js_bridge_invoke_proc -Wl,--export=js_bridge_eval_handle
```

### 2. Spawn a VM from the JS host

```js
// Via npm / bare specifier (preferred — package.json#main resolves
// to ./index.js):
import { createVM } from "mruby-js-bridge";

// Or via explicit path (vendored / unpublished consumers):
import { createVM } from "./vendor/mruby-js-bridge/index.js";

const vm = await createVM({ wasm: "/path/to/mruby.wasm" });
vm.eval("puts JSBridge.global[:navigator][:userAgent].to_s");
```

`createVM(options)` fetches the wasm, instantiates it with all required
imports (`js_bridge.*` for the bridge, `wasi_snapshot_preview1.*` for
`puts`, `Time.now`, `File.read`, etc.), runs `_start`, and returns a
**VM handle** with all per-instance state. Each `createVM()` call gets
an independent handle table + WASI state — multiple VMs can coexist in
one process (useful for tests, sandboxing, hot reload).

`vm.eval(source)` parses + runs Ruby source on the live VM. Each call
is auto-wrapped in a Fiber so `Value#await` works at top level.

The VM handle exposes:

| Property | Purpose |
|---|---|
| `vm.eval(src)` | parse + execute Ruby; returns 0 on success, 1 on parse/runtime error |
| `vm.fs` | Map-like facade over the tree VFS (`set` / `get` / `has` / `delete` / iteration / `populate` / `root`) |
| `vm.env` | mutable env hash — mutations after `_start` don't reach wasi-libc's environ cache, but `mruby-wasi-env` ENV reflects them via setenv |
| `vm.args` | mutable argv array |
| `vm.stdin` | `{ bytes, pushText(s) }` — feed STDIN |
| `vm.instance` | the underlying `WebAssembly.Instance` (for power users) |
| `vm.alloc` / `vm.get` / `vm.release` | low-level handle table access |
| `vm.handleCount()` | currently-allocated JS handles (for leak detection) |

Module-level exports:

| Export | Purpose |
|---|---|
| `createVM(options)` | the factory above |
| `Directory` / `File` | tree-VFS node classes for declarative population |
| `createFsFacade(root)` | wrap an arbitrary `Directory` tree as a Map-compatible fs facade (set/get/has/delete/iteration/clear/size/populate/root). Useful when you want to inspect or mutate a tree before handing it to `createVM({ fs })`, or to get the same facade behaviour against a sub-tree. |
| `debug` | `{ trace: false }` — global debug toggle (handle release / callback dispatch / WASI fd_read / path_open) |

#### `createVM` options

| Option | Default | Notes |
|---|---|---|
| `wasm` (string, required) | — | URL to mruby.wasm |
| `env` (object) | `{}` | initial environ, available to mruby via wasi-libc's getenv |
| `args` (string[]) | `["mruby-js-bridge"]` | initial argv (`main.c` puts `args[1..]` into Ruby `ARGV`) |
| `stdin` (string \| Uint8Array) | `""` | initial stdin payload for `STDIN.read` / `gets` |
| `fs` (Directory) | empty Directory | declarative initial tree (or use `vm.fs.set(...)` after creation) |
| `wasi` (object) | bundled in-memory impl | replacement `wasi_snapshot_preview1` import object |
| `onStart` (function) | calls `_start()` | post-instantiate callback; override for shims that need to bind the instance themselves |

#### Populating the virtual filesystem

```js
import { createVM, Directory, File } from "mruby-js-bridge";

// 1. Declarative — hand the whole tree to createVM.
const vm = await createVM({
  wasm: "/path/to/mruby.wasm",
  fs: new Directory({
    data: new Directory({
      "poem.vtt": new File(new TextEncoder().encode("WEBVTT\n...")),
    }),
    empty_dir: new Directory(),
  }),
});

// 2. Map-style after creation — auto-creates intermediate Directory nodes.
vm.fs.set("/config/app.json", new TextEncoder().encode("{}"));
```

`vm.fs` supports `set` / `get` / `has` / `delete` / `entries` / `keys` /
`values` / `Symbol.iterator` / `clear` / `size` (Map-compatible), plus
`populate(dir)` and `root` for tree access. Iteration yields only File
leaves, in tree-traversal order.

#### Swapping in a different WASI

For example, to use [`@bjorn3/browser_wasi_shim`](https://github.com/bjorn3/browser_wasi_shim)
(tree VFS, fd_readdir, OPFS, multiple preopens):

```js
import { createVM } from "mruby-js-bridge";
import { WASI } from "@bjorn3/browser_wasi_shim";

const wasi = new WASI([], [], [/* preopens */]);
const vm = await createVM({
  wasm: "/path/to/mruby.wasm",
  wasi: wasi.wasiImport,
  onStart: (instance) => wasi.start(instance),
});
```

When you pass `options.wasi`, `vm.fs` / `vm.env` / `vm.args` / `vm.stdin`
are absent from the returned object (your WASI owns that state — use
`"fs" in vm` to discriminate). The `js_bridge.*` imports (the JSBridge
layer itself) are always provided by this adapter regardless of which
WASI is used.

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

Expected: `167/167 tests pass (235 assertions)`. Exit code 0 on success,
1 on any failure.

## Dependencies

| Gem | Why |
|---|---|
| `mruby-method` | enables `method_missing` dispatch |
| `mruby-fiber` | required for `Value#await` (Fiber.yield/resume) |
| `mruby-compiler` | required for `evalRuby` (runtime `mrb_load_string`) |
| `mruby-io` *(optional)* | `File.read` / `File.open` — backed by the in-memory `fs` Map via WASI |
| `mruby-time` *(optional)* | `Time.now` — backed by WASI `clock_time_get` |
| `mruby-random` *(optional)* | `rand` / `Random` — backed by WASI `random_get` |

Tested against **mruby 4.0.0**.

## Related projects

This gem ships the **JS-host build** of upstream mruby on WebAssembly.
A sibling **CLI / wasmtime build** (same upstream mruby, no JS bridge)
lives under `spike/dist/mruby-wasm-cli/` — useful for sandboxing and
running mruby scripts from `wasmtime` / `node:wasi` / other preview1
hosts. Build it via `make cli-link` from the spike root.

If you're doing mruby on WASM more broadly, see also:

- **[ruby/ruby.wasm](https://github.com/ruby/ruby.wasm)** — official
  CRuby on WebAssembly. Heavier (full CRuby) but more compatible with
  CRuby gems. The structural inspiration for this gem; `createVM` is
  shaped after the same factory-returning-VM-handle pattern.
- **[mrubyedge/mrubyedge](https://github.com/mrubyedge/mrubyedge)** —
  Rust reimplementation of the mruby VM, optimised for edge runtimes
  / `no_std` embedding. Bytecode produced by upstream `mrbc` runs on
  both that VM and the wasm built by this gem, so a `.mrb` you compile
  once is portable across the two.

## License

MIT (see `mrbgem.rake`).
