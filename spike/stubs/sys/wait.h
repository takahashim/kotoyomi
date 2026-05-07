/* Stub for wasi-sysroot which lacks <sys/wait.h>.
 * mruby-io's io.c uses waitpid/WEXITSTATUS in the IO.popen path.
 * We don't actually spawn processes from the spike, so symbols can stay
 * unresolved (turned into wasm imports via -Wl,--allow-undefined). */
#ifndef _SYS_WAIT_H_STUB
#define _SYS_WAIT_H_STUB

#include <sys/types.h>

#define WNOHANG    1
#define WEXITSTATUS(x) ((x) & 0xff)
#define WIFEXITED(x)   1
#define WIFSIGNALED(x) 0
#define WTERMSIG(x)    0

extern pid_t waitpid(pid_t pid, int *status, int options);

#endif
