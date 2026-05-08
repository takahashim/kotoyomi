/*
 * mruby-wasi-stubs: linked-in stubs for the few POSIX symbols that
 * mruby-io's `io.c` (not the HAL) calls directly.
 *
 * Most of mruby-io's POSIX surface is routed through the HAL interface
 * (so hal-wasi-io can return ENOSYS at the HAL level without leaving
 * unresolved symbols at link time). But two functions are called from
 * inside mruby-io's main io.c, not via HAL:
 *
 *   - dup()      — used by `IO#dup` / `IO#initialize_copy` (io.c:symdup)
 *   - waitpid()  — used during popen child cleanup (io.c)
 *
 * wasi-libc doesn't ship either. Stubbing them at -1/ENOSYS satisfies
 * the linker; mruby-io's IO#dup and popen flows raise SystemCallError
 * at runtime instead of crashing the wasm at instantiation.
 *
 * Used by both wasi-js.rb (JS-host build) and wasi-cmd.rb (command build)
 * because both link against mruby-io.
 *
 * Types (pid_t etc.) come from spike/stubs/wasi-shims.h, force-included
 * via -include for every translation unit.
 */

#include <errno.h>
#include <stddef.h>

int dup(int fd) {
  (void)fd;
  errno = ENOSYS;
  return -1;
}

pid_t waitpid(pid_t pid, int *status, int options) {
  (void)pid;
  (void)status;
  (void)options;
  errno = ENOSYS;
  return -1;
}

/* --- mruby gem hooks --------------------------------------------------- */

#include <mruby.h>

void mrb_mruby_wasi_stubs_gem_init(mrb_state *mrb) { (void)mrb; }
void mrb_mruby_wasi_stubs_gem_final(mrb_state *mrb) { (void)mrb; }
