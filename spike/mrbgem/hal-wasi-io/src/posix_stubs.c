/*
 * Linked-in stubs for the two POSIX symbols that mruby-io's `io.c`
 * (not the HAL) calls directly:
 *
 *   - dup()      — used by `IO#dup` / `IO#initialize_copy` (io.c:symdup)
 *   - waitpid()  — used during popen child cleanup (io.c)
 *
 * Most of mruby-io's POSIX surface is routed through the HAL interface
 * defined in io_hal.c — for those, returning ENOSYS at the HAL level
 * is sufficient. But these two are called outside the HAL, so the
 * linker needs real symbol definitions even if they're never actually
 * invoked at runtime. Stubbing them at -1/ENOSYS keeps `IO#dup` and
 * popen flows raising `SystemCallError` instead of crashing the wasm
 * at instantiation.
 *
 * Types (pid_t etc.) come from include/wasi-shims.h, force-included
 * via -include for every translation unit (set up by the build_config
 * pointing at this gem's include/ directory).
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
