# mruby cross-build for WASI (wasm32-wasip1) — JS-host variant.
#
# Sibling to build_config/wasi-cmd.rb (command / wasmtime variant). This
# config is the JS-host build: includes mruby-wasm-js so the wasm
# carries the js_bridge.* primitive imports that the gem's JS adapter
# (mrbgem/mruby-wasm-js/js/index.js — `createVM` factory) satisfies.
#
# Requires: WASI_SDK_PATH environment variable pointing to an extracted
# wasi-sdk distribution (e.g. /opt/wasi-sdk).
#
# __dir__-relative paths below resolve to spike/stubs and spike/mrbgem;
# pass the absolute path via MRUBY_CONFIG (the Makefile does).
#
# Usage:
#   cd spike/mruby
#   WASI_SDK_PATH=/path/to/wasi-sdk rake \
#     MRUBY_CONFIG=$(realpath ../build_config/wasi-js.rb)

wasi_sdk = ENV.fetch("WASI_SDK_PATH") { abort "Set WASI_SDK_PATH" }
sysroot = "#{wasi_sdk}/share/wasi-sysroot"
clang = "#{wasi_sdk}/bin/clang"
ar = "#{wasi_sdk}/bin/llvm-ar"
target = "wasm32-wasip1"

MRuby::CrossBuild.new("wasi-js") do |conf|
  conf.toolchain :clang

  conf.cc.command = clang
  conf.cxx.command = "#{wasi_sdk}/bin/clang++"
  conf.linker.command = clang
  conf.archiver.command = ar

  common_flags = ["--target=#{target}", "--sysroot=#{sysroot}"]
  # Enable setjmp/longjmp via WebAssembly Exception Handling proposal.
  # mruby uses sjlj for exceptions and GC mark scan; modern browsers
  # (Chrome 95+, Safari 15.2+, FF 102+) support EH, so this is fine in practice.
  sjlj_flags = ["-mllvm", "-wasm-enable-sjlj"]
  # POSIX shim headers (live inside hal-wasi-io's include/): empty
  # `pwd.h` / `sys/wait.h` for wasi-sysroot gaps, and `wasi-shims.h`
  # which declares the missing function prototypes (dup, waitpid, ...)
  # that mruby-io's io.c references. Listed FIRST so it takes precedence
  # over wasi-sysroot.
  shim_dir = File.expand_path("../mrbgem/hal-wasi-io/include", __dir__)
  stub_flags = ["-isystem", shim_dir, "-include", "#{shim_dir}/wasi-shims.h"]
  conf.cc.flags.concat(common_flags + sjlj_flags + stub_flags)
  conf.cxx.flags.concat(common_flags + sjlj_flags + stub_flags)
  conf.linker.flags.concat(common_flags)

  # Allow undefined imports (we declare them via __attribute__((import_module)))
  conf.linker.flags << "-Wl,--allow-undefined"

  # Reactor module: export `_initialize` (runs ctors, then returns) instead
  # of `_start`. The JS host keeps the instance alive and drives execution
  # by calling exports (`js_eval_handle`, `js_invoke_proc`). The mruby VM
  # itself is brought up by a __attribute__((constructor)) inside the gem
  # (callback.c), so no separate main.c is needed.
  conf.linker.flags << "-mexec-model=reactor"

  # Link the SJLJ runtime support; provides __wasm_setjmp / __wasm_longjmp /
  # __wasm_setjmp_test that the SJLJ-via-EH lowering needs.
  conf.linker.libraries << "setjmp"

  # Disable features that need POSIX bits wasi-libc lacks
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  # default-no-stdio = stdlib + math, minus the stdio gems (mruby-bin-mrb,
  # mruby-bin-mirb, mruby-bin-mrbc, mruby-bin-strip).  We add what we
  # actually need below.  mruby 4.0.0 doesn't include mruby-regexp here
  # so the old `super` workaround from HEAD is no longer needed.
  conf.gembox "default-no-stdio"

  # mrb_load_string requires the parser, which lives in mruby-compiler.
  conf.gem core: "mruby-compiler"

  # WASI HAL for mruby-io. Loaded BEFORE mruby-io so the latter's HAL
  # auto-detector finds it (matches /^hal-.*-io$/ and skips its
  # hal-posix-io fallback). hal-wasi-io routes all POSIX-level IO
  # primitives through the HAL interface; unsupported ops (dup, fork,
  # umask, flock, getpwnam, ...) return ENOSYS at the HAL level without
  # leaving unresolved symbols at link time.
  # hal-wasi-io also ships symbol stubs for the few POSIX functions
  # (dup, waitpid) that mruby-io's main io.c calls directly outside the
  # HAL — those compile-time references would otherwise leave unresolved
  # symbols at link time.
  conf.gem File.expand_path("../mrbgem/hal-wasi-io", __dir__)
  conf.gem core: "mruby-io"

  # mruby-method enables Object#method_missing dispatch (used by
  # JSBridge::Value to forward unknown method calls to JS).
  conf.gem core: "mruby-method"

  # Time / Random — used by Ruby code; underlying WASI primitives
  # (clock_time_get / random_get) are implemented in adapter.js.
  conf.gem core: "mruby-time"
  conf.gem core: "mruby-random"

  # Our gems
  conf.gem File.expand_path("../mrbgem/mruby-wasm-js", __dir__)
  # mruby-wasi-dir provides Dir.entries / Dir.mkdir / Dir.rmdir /
  # Dir.exist? on top of wasi-libc's <dirent.h>, which the bridge's
  # WASI imports (path_open(O_DIRECTORY) / fd_readdir / ...) implement.
  conf.gem File.expand_path("../mrbgem/mruby-wasi-dir", __dir__)
  # mruby-wasi-env provides ENV[] / ENV[]= / ENV.each / ... backed by
  # wasi-libc's getenv/setenv/environ (populated from environ_get).
  conf.gem File.expand_path("../mrbgem/mruby-wasi-env", __dir__)

  # We only need libmruby.a; the spike provides its own main via main/main.c
  conf.bins = []
end
