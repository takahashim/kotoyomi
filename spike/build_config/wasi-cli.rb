# mruby cross-build for WASI (wasm32-wasip1) — CLI / wasmtime variant.
#
# Same toolchain + most gems as build_config/wasi.rb, but:
#   - NO mruby-wasm-js (this build is meant to run on wasmtime / wasi-libc
#     hosts that don't provide the js_bridge.* imports)
#   - NO mruby-method (only needed for JSBridge::Value#method_missing)
#   - INCLUDES mruby-bin-mruby, which produces a `bin/mruby` CLI wasm that
#     reads a Ruby script from argv (or stdin if no arg) and executes it
#
# Output: $(mruby)/build/wasi-cli/bin/mruby — a wasm32-wasip1 module that
# can be run as `wasmtime --dir=. mruby script.rb`.
#
# Sibling to wasi.rb which is for the JS-host build (browser/Node via the
# mruby-wasm-js JS adapter).

wasi_sdk = ENV.fetch("WASI_SDK_PATH") { abort "Set WASI_SDK_PATH" }
sysroot = "#{wasi_sdk}/share/wasi-sysroot"
clang = "#{wasi_sdk}/bin/clang"
ar = "#{wasi_sdk}/bin/llvm-ar"
target = "wasm32-wasip1"

MRuby::CrossBuild.new("wasi-cli") do |conf|
  conf.toolchain :clang

  conf.cc.command = clang
  conf.cxx.command = "#{wasi_sdk}/bin/clang++"
  conf.linker.command = clang
  conf.archiver.command = ar

  common_flags = ["--target=#{target}", "--sysroot=#{sysroot}"]
  # `-wasm-use-legacy-eh=false` switches clang's SJLJ lowering to the
  # modern Wasm Exception Handling proposal (`try_table`) instead of
  # the legacy `try`/`catch` instructions. wasmtime ≥36 only supports
  # the modern form, so this flag is required for the CLI build to
  # parse on those versions.
  sjlj_flags = ["-mllvm", "-wasm-enable-sjlj",
                "-mllvm", "-wasm-use-legacy-eh=false"]
  stubs_dir = File.expand_path("../stubs", __dir__)
  stub_flags = ["-isystem", stubs_dir, "-include", "#{stubs_dir}/wasi-shims.h"]
  conf.cc.flags.concat(common_flags + sjlj_flags + stub_flags)
  conf.cxx.flags.concat(common_flags + sjlj_flags + stub_flags)
  conf.linker.flags.concat(common_flags)

  conf.linker.libraries << "setjmp"

  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  conf.gembox "default-no-stdio"

  # Runtime parser (for `mrb_load_string` from the CLI's eval path)
  conf.gem core: "mruby-compiler"

  # WASI HAL for mruby-io. Loaded BEFORE mruby-io so the latter's HAL
  # auto-detector finds it (matches /^hal-.*-io$/ and skips the
  # hal-posix-io fallback). Without this, mruby-io would auto-load
  # hal-posix-io which references POSIX functions (dup, fork, ...) that
  # wasi-libc doesn't ship — making the wasm fail to link.
  conf.gem File.expand_path("../mrbgem/hal-wasi-io", __dir__)
  conf.gem core: "mruby-io"
  conf.gem core: "mruby-time"
  conf.gem core: "mruby-random"

  # Symbol stubs for the few POSIX functions mruby-io's main io.c
  # references directly (not via HAL): dup, waitpid. Shared with the
  # JS-host build.
  conf.gem File.expand_path("../mrbgem/mruby-wasi-stubs", __dir__)

  # Sibling sister-gems (host-agnostic).
  conf.gem File.expand_path("../mrbgem/mruby-wasi-dir", __dir__)
  conf.gem File.expand_path("../mrbgem/mruby-wasi-env", __dir__)

  # CLI entry point: produces `bin/mruby` that takes argv[1] = script path
  # (or reads stdin if no script given) and executes it. Same UX as the
  # native `mruby` binary.
  conf.gem core: "mruby-bin-mruby"

  conf.bins = ["mruby"]
end
