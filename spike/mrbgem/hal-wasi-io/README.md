# hal-wasi-io

WASI HAL backend for `mruby-io` on `wasm32-wasip1`.

`mruby-io` ships with a HAL auto-loader that, for any `MRuby::CrossBuild`
including a sibling gem matching `/^hal-.*-io$/`, uses that gem instead
of the default `hal-posix-io` fallback. Listing this gem before
`mruby-io` in your build config is enough to wire it up:

```ruby
conf.gem File.expand_path("path/to/hal-wasi-io", __dir__)
conf.gem core: "mruby-io"
```

This gem covers three responsibilities:

1. **HAL implementation** (`src/io_hal.c`). Routes mruby-io's POSIX-level
   file/seek/read/write/close calls to wasi-libc; returns `ENOSYS` for
   ops wasi-libc doesn't support (locking, mode/ownership chmod-ish, ...).
2. **Direct-reference symbol stubs** (`src/posix_stubs.c`). mruby-io's
   `io.c` calls a few POSIX functions (`dup`, `waitpid`) outside of the
   HAL. They aren't exercised at runtime in the wasi build, but the
   compile-time references would leave undefined symbols at link time.
   The stubs exist purely to satisfy the linker.
3. **Header shims** (`include/`). wasi-libc lacks `<pwd.h>`,
   `<sys/wait.h>`, and prototypes for `dup`/`waitpid`/`umask`/etc.
   The shipped headers (`pwd.h`, `sys/wait.h`, `wasi-shims.h`) plug
   those gaps.

## Required build_config wiring

Currently mruby's gem system has no clean way for a gem to inject `cflags`
into other gems' compilation. The header shims must be wired up in the
**consumer's** `build_config` so they are visible to mruby-io / mrbgems
when those compile, not only when this gem compiles.

```ruby
shim_dir = File.expand_path("path/to/hal-wasi-io/include")
conf.cc.flags.concat([
  # Make pwd.h / sys/wait.h findable, ahead of wasi-sysroot.
  "-isystem", shim_dir,
  # Force-include wasi-shims.h so dup/waitpid/umask/getpwnam/struct passwd
  # prototypes are visible to every TU (mruby-io's io.c references them
  # without including their natural POSIX headers).
  "-include", "#{shim_dir}/wasi-shims.h",
])
conf.cxx.flags.concat([
  "-isystem", shim_dir,
  "-include", "#{shim_dir}/wasi-shims.h",
])
```

Without those flags, mruby-io fails to compile against wasi-sysroot
(missing `dup`, `pid_t`, `struct passwd`, etc.).

See `spike/build_config/wasi-js.rb` and `wasi-cmd.rb` in this repo for
working examples of both the `conf.gem` line and the cflags above.

## Why force-include rather than `<unistd.h>` etc.

The shimmed prototypes are intentionally **not** put in headers named
after their POSIX origin (`<unistd.h>`, `<sys/wait.h>`). wasi-libc
already provides a partial `<unistd.h>`; replacing it would be invasive
and brittle. Force-including a single shim header that just adds the
missing declarations is the smallest workable patch, and it makes the
wasi-specific surface easy to audit in one place.

## Runtime behaviour

The stub functions in `src/posix_stubs.c` (`dup`, `waitpid`) set
`errno = ENOSYS` and return `-1`. Calling `IO#dup` or popen-style flows
in the wasi build therefore surfaces a Ruby `SystemCallError` rather
than crashing the wasm. Real implementations are out of scope: wasi
preview1 has no `dup` or process model, and the spike doesn't need
them.
