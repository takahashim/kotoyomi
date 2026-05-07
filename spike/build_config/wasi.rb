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

  # default-no-stdio = stdlib + math. Adds mruby-io and mruby-compiler
  # explicitly so we get Kernel#puts (from io_puts) plus mrb_load_string
  # without pulling in mruby-socket (needs netdb.h) etc.
  conf.gembox "default-no-stdio"

  # Drop mruby-regexp.
  #
  # Upstream bug (mruby HEAD as of 2026-05): mrblib/string_regexp.rb
  # redefines String#split in Ruby, then falls back to `super` for
  # plain-string patterns. mruby's method table (class.c:mt_put)
  # overwrites the existing C-level mrb_str_split_m entry on String, and
  # OP_SUPER (vm.c) walks to String->super (Object) which has no split.
  # Net result: `"a\nb".split("\n")` raises
  # `NoMethodError: no superclass method 'split' for String`.
  # The gem's own tests only exercise the Regexp-pattern path, so the
  # super fallback isn't covered.
  #
  # kotoyomi doesn't need regex support, so the cleanest workaround is
  # to drop the gem entirely. (Restore once upstream aliases the C
  # method via `alias __core_split split` before redefinition.)
  conf.gems.instance_variable_get(:@ary).reject! { |g| g.name == "mruby-regexp" }

  # mrb_load_string requires the parser, which lives in mruby-compiler.
  conf.gem core: "mruby-compiler"

  # mruby-io provides Kernel#puts. file.c needs pwd.h stub from spike/stubs/,
  # io.c needs sys/wait.h stub. Symbols like waitpid stay unresolved and
  # become wasm imports (we never call them at runtime).
  conf.gem core: "mruby-io"

  # mruby-method enables Object#method_missing dispatch (used by
  # JSBridge::Value to forward unknown method calls to JS).
  conf.gem core: "mruby-method"

  # Our spike mrbgem (mruby ↔ JS bridge)
  conf.gem File.expand_path("../mrbgem/mruby-js-bridge", __dir__)

  # We only need libmruby.a; the spike provides its own main via main/main.c
  conf.bins = []
end
