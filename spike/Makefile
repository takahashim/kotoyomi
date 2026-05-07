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
# Build config lives outside the mruby clone (which is gitignored) so we
# don't have to track files in someone else's source tree.
MRUBY_CONFIG := $(CURDIR)/build_config/wasi.rb
LIBMRUBY := $(MRUBY_DIR)/build/wasi/lib/libmruby.a

MAIN_C := $(CURDIR)/main/main.c
HOST_DIR := $(CURDIR)/host
HOST_WASM := $(HOST_DIR)/mruby.wasm

CLANG := $(WASI_SDK_DIR)/bin/clang
SYSROOT := $(WASI_SDK_DIR)/share/wasi-sysroot
TARGET := wasm32-wasip1

.PHONY: all download wasi-sdk mruby link serve test clean distclean

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

mruby: wasi-sdk $(LIBMRUBY)

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

clean:
	rm -rf $(MRUBY_DIR)/build/wasi
	rm -f $(HOST_WASM)

distclean: clean
	rm -rf $(WASI_SDK_DIR) $(WASI_SDK_OK)
	rm -f $(WASI_SDK_TAR)
