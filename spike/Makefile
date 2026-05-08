# spike/mruby-bridge build orchestration
#
# Targets:
#   make wasi-sdk    Extract vendored wasi-sdk tarball
#   make mruby       Build mruby with wasi config
#   make wasm        Copy built wasm into host/
#   make serve       Start a local server on host/
#   make all         wasi-sdk → mruby → wasm
#   make clean       Remove built artifacts (mruby/build, host/mruby.wasm)

WASI_SDK_VERSION := 33.0
WASI_SDK_URL := https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-33/wasi-sdk-33.0-arm64-macos.tar.gz
WASI_SDK_DIR := $(CURDIR)/vendor/wasi-sdk
WASI_SDK_TAR := $(CURDIR)/vendor/wasi-sdk.tar.gz
WASI_SDK_OK := $(CURDIR)/vendor/.wasi-sdk-ok
export WASI_SDK_PATH := $(WASI_SDK_DIR)

MRUBY_DIR := $(CURDIR)/mruby
MRUBY_REPO := https://github.com/mruby/mruby.git
# Pinned tag of upstream mruby. Bump intentionally — mruby HEAD has had
# incompatible changes (e.g. mruby-regexp's String#split breakage).
MRUBY_TAG := 4.0.0
# Build config lives outside the mruby clone (which is gitignored) so we
# don't have to track files in someone else's source tree.
MRUBY_CONFIG := $(CURDIR)/build_config/wasi.rb
LIBMRUBY := $(MRUBY_DIR)/build/wasi/lib/libmruby.a

MAIN_C := $(CURDIR)/main/main.c
HOST_DIR := $(CURDIR)/host
HOST_WASM := $(HOST_DIR)/mruby.wasm

# CLI / wasmtime variant — same gem set minus mruby-js-bridge, plus
# mruby-bin-mruby for a standard `mruby` CLI entry. See
# build_config/wasi-cli.rb for rationale.
MRUBY_CONFIG_CLI := $(CURDIR)/build_config/wasi-cli.rb
LIBMRUBY_CLI := $(MRUBY_DIR)/build/wasi-cli/lib/libmruby.a
HOST_WASM_CLI := $(HOST_DIR)/mruby-cli.wasm
DIST_DIR_CLI := $(CURDIR)/dist/mruby-wasm-cli

CLANG := $(WASI_SDK_DIR)/bin/clang
SYSROOT := $(WASI_SDK_DIR)/share/wasi-sysroot
TARGET := wasm32-wasip1

.PHONY: all download wasi-sdk mruby link serve test dist clean distclean \
        mruby-cli cli-link smoke-cli dist-cli

all: link

# 1) Download the tarball (resumable) and verify it's valid gzip before extract.
download: $(WASI_SDK_TAR)
	@gzip -t $(WASI_SDK_TAR) 2>/dev/null && echo "tarball OK ($$(du -h $(WASI_SDK_TAR) | cut -f1))" \
	  || (echo "tarball is incomplete or corrupt — re-running curl --continue-at -"; \
	      curl -L --continue-at - -o $(WASI_SDK_TAR) $(WASI_SDK_URL); \
	      gzip -t $(WASI_SDK_TAR) || (echo "still bad, delete $(WASI_SDK_TAR) and retry" && exit 1))

$(WASI_SDK_TAR):
	@mkdir -p $(CURDIR)/vendor
	curl -L --continue-at - -o $(WASI_SDK_TAR) $(WASI_SDK_URL)

# 2) Extract only after the tarball passes integrity check.
wasi-sdk: $(WASI_SDK_OK)

$(WASI_SDK_OK): $(WASI_SDK_TAR)
	@gzip -t $(WASI_SDK_TAR) || (echo "ERROR: $(WASI_SDK_TAR) is not a complete gzip file. Run 'make download' first." && exit 1)
	rm -rf $(WASI_SDK_DIR)
	mkdir -p $(WASI_SDK_DIR)
	tar -xzf $(WASI_SDK_TAR) -C $(WASI_SDK_DIR) --strip-components=1
	@test -x $(WASI_SDK_DIR)/bin/clang || (echo "wasi-sdk extraction failed" && exit 1)
	touch $(WASI_SDK_OK)
	@echo "wasi-sdk ready at $(WASI_SDK_DIR)"

mruby: wasi-sdk $(MRUBY_DIR)/.git $(LIBMRUBY)

# Shallow-clone mruby pinned to MRUBY_TAG. Skipped if the directory
# already exists (so a developer who manually checked out a different
# rev won't be silently overwritten).
$(MRUBY_DIR)/.git:
	@echo "cloning mruby $(MRUBY_TAG) into $(MRUBY_DIR)..."
	git clone --depth 1 --branch $(MRUBY_TAG) $(MRUBY_REPO) $(MRUBY_DIR)

$(LIBMRUBY):
	cd $(MRUBY_DIR) && rake MRUBY_CONFIG=$(MRUBY_CONFIG)

link: mruby $(HOST_WASM)

$(HOST_WASM): $(MAIN_C) $(LIBMRUBY) | $(HOST_DIR)
	$(CLANG) --target=$(TARGET) --sysroot=$(SYSROOT) \
	  -mllvm -wasm-enable-sjlj \
	  -DMRB_NO_BOXING -DMRB_UTF8_STRING \
	  -I$(MRUBY_DIR)/include \
	  -I$(MRUBY_DIR)/build/wasi/include \
	  -Wl,--allow-undefined \
	  -Wl,--export=js_bridge_invoke_proc \
	  -Wl,--export=js_bridge_eval_handle \
	  -o $(HOST_WASM) \
	  $(MAIN_C) $(LIBMRUBY) \
	  -lsetjmp
	@echo "Built $(HOST_WASM)"

$(HOST_DIR):
	mkdir -p $(HOST_DIR)

serve:
	cd $(CURDIR) && ruby -run -e httpd . -p 8001
	# Open http://localhost:8001/host/sample/ for the kotoyomi sample,
	# or http://localhost:8001/host/ for the spike test landing page.

test: link
	node mrbgem/mruby-js-bridge/wasm_spec/runner.mjs

# ---------------------------------------------------------------------------
# `make dist` — assemble a publishable bundle of mruby-js-bridge under
# dist/mruby-js-bridge/ with adapter.js + the built mruby.wasm + README +
# LICENSE + package.json. The bundle can be consumed as:
#   - cp -r dist/mruby-js-bridge/ /path/to/some/project/  (drop-in)
#   - npm pack / npm publish  (when ready)
#   - tarball for GitHub Releases  (Phase B)
# Version is hardcoded to 0.0.0-dev; bump before publishing.
# ---------------------------------------------------------------------------
DIST_DIR := $(CURDIR)/dist/mruby-js-bridge
GEM_DIR := $(CURDIR)/mrbgem/mruby-js-bridge
DIST_VERSION := 0.0.0-dev

dist: link
	@rm -rf $(DIST_DIR)
	@mkdir -p $(DIST_DIR)
	# Copy every .js file in js/ — globbing avoids drift when new
	# internal modules (_memory.js etc.) get added to the gem.
	cp $(GEM_DIR)/js/*.js   $(DIST_DIR)/
	cp $(GEM_DIR)/README.md $(DIST_DIR)/README.md
	cp $(GEM_DIR)/LICENSE   $(DIST_DIR)/LICENSE
	cp $(HOST_WASM)         $(DIST_DIR)/mruby.wasm
	# package.json's `files` list is regenerated to match the actual
	# .js files copied above.
	$(eval JS_FILES := $(notdir $(wildcard $(GEM_DIR)/js/*.js)))
	$(eval JS_FILES_JSON := $(shell printf '"%s", ' $(JS_FILES) "mruby.wasm" "README.md" "LICENSE" | sed 's/, $$//'))
	@printf '%s\n' \
	  '{' \
	  '  "name": "mruby-js-bridge",' \
	  '  "version": "$(DIST_VERSION)",' \
	  '  "description": "Minimal mruby ↔ JavaScript bridge for WASM hosts",' \
	  '  "type": "module",' \
	  '  "main": "./index.js",' \
	  '  "exports": {' \
	  '    ".": "./index.js",' \
	  '    "./wasm": "./mruby.wasm"' \
	  '  },' \
	  '  "files": [$(JS_FILES_JSON)],' \
	  '  "license": "MIT",' \
	  '  "engines": { "node": ">=18" }' \
	  '}' \
	  > $(DIST_DIR)/package.json
	@echo ""
	@echo "Built dist/mruby-js-bridge/ (version $(DIST_VERSION)):"
	@ls -lh $(DIST_DIR)
	@echo ""
	@echo "Use it from a consumer project:"
	@echo "  cp -r dist/mruby-js-bridge/ ../my-project/vendor/"
	@echo "  # ESM:"
	@echo "    import { createVM } from 'mruby-js-bridge'  # via package.json main"
	@echo "    # or explicit path:"
	@echo "    import { createVM } from './vendor/mruby-js-bridge/index.js'"
	@echo "    const vm = await createVM({ wasm: new URL('./vendor/mruby-js-bridge/mruby.wasm', import.meta.url).href })"

# ---------------------------------------------------------------------------
# `make cli-link` — build the CLI / wasmtime variant (mruby-bin-mruby
# entry point, no JS bridge). Produces host/mruby-cli.wasm which can run
# on wasmtime, wasmer, or any other preview1-compatible host.
# ---------------------------------------------------------------------------

mruby-cli: wasi-sdk $(MRUBY_DIR)/.git $(LIBMRUBY_CLI)

$(LIBMRUBY_CLI):
	cd $(MRUBY_DIR) && rake MRUBY_CONFIG=$(MRUBY_CONFIG_CLI)

cli-link: mruby-cli $(HOST_WASM_CLI)

# mruby-bin-mruby's CrossBuild output is bin/mruby (a wasm file in our
# wasm32-wasip1 target). Copy it under a .wasm extension for clarity.
$(HOST_WASM_CLI): $(LIBMRUBY_CLI) | $(HOST_DIR)
	cp $(MRUBY_DIR)/build/wasi-cli/bin/mruby $(HOST_WASM_CLI)
	@echo "Built $(HOST_WASM_CLI)"

# `make smoke-cli` — sanity check that the CLI wasm boots and Ruby
# basics (puts / Time / ENV / File / Dir / rand) work. Driven via Node's
# built-in WASI module since wasmtime ≥36 dropped support for the
# legacy exception bytecode that clang's SJLJ implementation emits
# (see notes/known-issues in the gem README). Node's WASI accepts
# this bytecode and is always available because the JS-host workflow
# already requires Node.
smoke-cli: cli-link
	@node --experimental-wasi-unstable-preview1 host/run-cli-node.mjs 2>&1 \
	  | grep -v ExperimentalWarning | grep -v "Use \`node"

dist-cli: cli-link
	@rm -rf $(DIST_DIR_CLI)
	@mkdir -p $(DIST_DIR_CLI)
	cp $(HOST_WASM_CLI) $(DIST_DIR_CLI)/mruby.wasm
	cp $(GEM_DIR)/LICENSE $(DIST_DIR_CLI)/LICENSE
	@printf '%s\n' \
	  '# mruby-wasm-cli' \
	  '' \
	  'CLI / wasmtime build of upstream mruby compiled to `wasm32-wasip1`.' \
	  'Sibling distribution to `mruby-js-bridge` — same upstream mruby and' \
	  'the same `mruby-wasi-dir` / `mruby-wasi-env` mgems, but **without** the' \
	  'JS bridge. Runs on any preview1-compatible WASI host (wasmtime,' \
	  'wasmer, browser_wasi_shim, etc.).' \
	  '' \
	  '## Usage' \
	  '' \
	  '```bash' \
	  '# Node has built-in WASI (always available, accepts our bytecode):' \
	  'node --experimental-wasi-unstable-preview1 run-cli-node.mjs script.rb' \
	  '' \
	  '# wasmtime ≥36 currently cannot load this build because clang emits' \
	  '# legacy exception bytecode (for SJLJ) that wasmtime dropped.' \
	  '# Tracking issue: see toolchain notes in the gem README.' \
	  '```' \
	  '' \
	  '`mruby.wasm` is `mruby-bin-mruby` compiled to wasm32-wasip1, so it' \
	  'accepts the same CLI surface as native `mruby`: pass a script path' \
	  'as argv, or pipe Ruby source on stdin.' \
	  '' \
	  '## What is included' \
	  '' \
	  '- upstream mruby 4.0.0' \
	  '- `mruby-compiler` — runtime parsing/eval' \
	  '- `mruby-io` — File / IO via wasi-libc' \
	  '- `mruby-time` / `mruby-random` — Time.now, rand' \
	  '- `mruby-wasi-dir` — Dir.entries / mkdir / rmdir / exist?' \
	  '- `mruby-wasi-env` — ENV[] / each / keys / etc' \
	  '' \
	  '## Related projects' \
	  '' \
	  '- [`mruby-js-bridge`](../mruby-js-bridge/) — sibling package: same' \
	  '  upstream mruby plus a `js_bridge` C primitive layer + JS adapter' \
	  '  (`createVM` factory) for browser / Node hosts.' \
	  '- [`ruby/ruby.wasm`](https://github.com/ruby/ruby.wasm) — official' \
	  '  CRuby on WebAssembly. Heavier (full CRuby) but more compatible' \
	  '  with CRuby gems.' \
	  '- [`mrubyedge/mrubyedge`](https://github.com/mrubyedge/mrubyedge) —' \
	  '  Rust reimplementation of the mruby VM, optimised for edge' \
	  '  runtimes / `no_std` embedding. Smaller binary, subset of mruby' \
	  '  behaviour. Bytecode produced by upstream `mrbc` runs on both' \
	  '  this distribution and `mruby/edge`.' \
	  > $(DIST_DIR_CLI)/README.md
	@echo ""
	@echo "Built dist/mruby-wasm-cli/ (version $(DIST_VERSION)):"
	@ls -lh $(DIST_DIR_CLI)
	@echo ""
	@echo "Try it (Node has built-in WASI; wasmtime ≥36 currently can't load"
	@echo "the legacy SJLJ exception bytecode clang emits — use Node for now):"
	@echo "  node --experimental-wasi-unstable-preview1 host/run-cli-node.mjs path/to/script.rb"

clean:
	rm -rf $(MRUBY_DIR)/build/wasi $(MRUBY_DIR)/build/wasi-cli
	rm -f $(HOST_WASM) $(HOST_WASM_CLI)
	rm -rf $(CURDIR)/dist

distclean: clean
	rm -rf $(WASI_SDK_DIR) $(WASI_SDK_OK)
	rm -f $(WASI_SDK_TAR)
