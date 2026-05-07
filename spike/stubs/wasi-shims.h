/* Force-included for the wasi build (-include via build_config).
 * Declares POSIX functions that wasi-libc omits but mruby-io's source
 * references in code paths we don't actually exercise (process spawn,
 * fd duplication, etc.). They stay as wasm imports and must never be
 * called at runtime in the spike. */
#ifndef _KOTOYOMI_WASI_SHIMS_H
#define _KOTOYOMI_WASI_SHIMS_H

#include <sys/types.h>

extern int dup(int fd);
extern int dup2(int oldfd, int newfd);
extern pid_t waitpid(pid_t pid, int *status, int options);

#endif
