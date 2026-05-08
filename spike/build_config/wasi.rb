# mruby cross-build for WASI (wasm32-wasip1)
#
# Requires: WASI_SDK_PATH environment variable pointing to an extracted
# wasi-sdk distribution (e.g. /opt/wasi-sdk).
#
# Lives at spike/build_config/wasi.rb (outside the mruby clone, which is
# gitignored). __dir__-relative paths below resolve to spike/stubs and
# spike/mrbgem; pass the absolute path via MRUBY_CONFIG (the Makefile does).
#
# Usage:
#   cd spike/mruby
#   WASI_SDK_PATH=/path/to/wasi-sdk rake \
#     MRUBY_CONFIG=$(realpath ../build_config/wasi.rb)

wasi_sdk = ENV.fetch("WASI_SDK_PATH") { abort "Set WASI_SDK_PATH" }
sysroot = "#{wasi_sdk}/share/wasi-sysroot"
clang = "#{wasi_sdk}/bin/clang"
ar = "#{wasi_sdk}/bin/llvm-ar"
target = "wasm32-wasip1"

MRuby::CrossBuild.new("wasi") do |conf|
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
  # Stub directory for POSIX headers wasi-sysroot lacks (e.g. pwd.h, sys/wait.h)
  # plus a force-included shim that declares missing functions (dup, waitpid).
  # Listed FIRST so it takes precedence over wasi-sysroot.
  stubs_dir = File.expand_path("../stubs", __dir__)
  stub_flags = ["-isystem", stubs_dir, "-include", "#{stubs_dir}/wasi-shims.h"]
  conf.cc.flags.concat(common_flags + sjlj_flags + stub_flags)
  conf.cxx.flags.concat(common_flags + sjlj_flags + stub_flags)
  conf.linker.flags.concat(common_flags)

  # Allow undefined imports (we declare them via __attribute__((import_module)))
  conf.linker.flags << "-Wl,--allow-undefined"

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

  # mruby-io provides Kernel#puts (the io_puts implementation).  In
  # mruby 4.0.0 the POSIX backend was extracted into a separate HAL gem
  # (`hal-posix-io`), which mruby-io's mrbgem.rake auto-loads when the
  # build host is POSIX-like.  io_hal.c references POSIX functions that
  # wasi-libc doesn't ship (umask, flock, getpwnam, fork, ...); they
  # stay as wasm imports and are no-op'd in adapter.js (kotoyomi never
  # calls File.open / Process.spawn / IO.popen etc.).
  conf.gem core: "mruby-io"

  # mruby-method enables Object#method_missing dispatch (used by
  # JSBridge::Value to forward unknown method calls to JS).
  conf.gem core: "mruby-method"

  # Time / Random — used by Ruby code; underlying WASI primitives
  # (clock_time_get / random_get) are implemented in adapter.js.
  conf.gem core: "mruby-time"
  conf.gem core: "mruby-random"

  # Our gems
  conf.gem File.expand_path("../mrbgem/mruby-js-bridge", __dir__)
  # mruby-wasi-dir provides Dir.entries / Dir.mkdir / Dir.rmdir /
  # Dir.exist? on top of wasi-libc's <dirent.h>, which the bridge's
  # WASI imports (path_open(O_DIRECTORY) / fd_readdir / ...) implement.
  conf.gem File.expand_path("../mrbgem/mruby-wasi-dir", __dir__)

  # We only need libmruby.a; the spike provides its own main via main/main.c
  conf.bins = []
end
