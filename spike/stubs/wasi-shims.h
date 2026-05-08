/* Force-included for the wasi build (-include via build_config).
 * Declares POSIX functions that wasi-libc omits but mruby-io / hal-posix-io
 * reference in code paths we don't actually exercise (file mode bits,
 * process spawn, pipe / fork, password DB lookup, etc.). They stay as
 * undefined wasm imports (resolved by adapter.js to no-op stubs) and
 * must never be called at runtime in the spike. */
#ifndef _KOTOYOMI_WASI_SHIMS_H
#define _KOTOYOMI_WASI_SHIMS_H

#include <sys/types.h>

/* fd duplication / process control — referenced by mruby-io / hal-posix-io */
extern int dup(int fd);
extern int dup2(int oldfd, int newfd);
extern pid_t waitpid(pid_t pid, int *status, int options);
extern int pipe(int fds[2]);
extern pid_t fork(void);
extern int execl(const char *path, const char *arg, ...);

/* file mode mask — referenced by mruby-io / hal-posix-io */
typedef unsigned int mode_t;
extern mode_t umask(mode_t mask);

/* passwd DB — hal-posix-io's getpwnam usage in mrb_hal_io_gethome.
 * `struct passwd` needs only a `pw_dir` member for that code path. */
struct passwd {
  const char *pw_dir;
};
extern struct passwd *getpwnam(const char *name);

#endif
