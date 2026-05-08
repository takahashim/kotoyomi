/*
 * io_hal.c - WASI HAL implementation for mruby-io
 *
 * Adapted from upstream mruby's hal-posix-io (BSD/MIT-licensed) for the
 * wasm32-wasip1 target. Identical surface to hal-posix-io but:
 *
 *   - Drops references to POSIX functions wasi-libc doesn't ship
 *     (dup, pipe, fork, execl, waitpid, flock, umask, getpwnam).
 *     Those operations return -1 with errno=ENOSYS at the HAL level
 *     so Ruby code that touches IO.popen / IO.pipe / Process.spawn /
 *     File.flock / etc. surfaces NotImplementedError-shaped messages
 *     rather than crashing the wasm linker with unresolved symbols.
 *
 *   - select() and friends are stubbed (WASI's poll_oneoff is a
 *     different ABI; mapping it here would be substantial. Add when
 *     a Ruby caller actually needs it).
 *
 *   - fcntl is honoured for the F_GETFD/F_SETFD/FD_CLOEXEC paths only
 *     (wasi-libc accepts these but the bits are mostly no-ops).
 *
 * The available subset (open/close/read/write/lseek/stat/fstat/lstat/
 * chmod/unlink/rename/symlink/readlink/realpath/getcwd/getenv/
 * ftruncate/isatty) uses wasi-libc directly — exactly the same code
 * path as hal-posix-io.
 */

#include <mruby.h>
#include "io_hal.h"

#include <sys/types.h>
#include <sys/stat.h>
#include <sys/time.h>

#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

/* --- helpers ------------------------------------------------------------ */

static void
convert_stat(const struct stat *src, mrb_io_stat *dst)
{
  /* wasi-libc uses POSIX.1-2008 timespec members (st_atim/mtim/ctim).
   * Macros for st_atime etc. are *not* expected to be present, but
   * accept either form like upstream hal-posix-io does. */
  time_t atime_val, mtime_val, ctime_val;
#if defined(st_atime)
  atime_val = src->st_atime;
  mtime_val = src->st_mtime;
  ctime_val = src->st_ctime;
#else
  atime_val = src->st_atim.tv_sec;
  mtime_val = src->st_mtim.tv_sec;
  ctime_val = src->st_ctim.tv_sec;
#endif
#undef st_atime
#undef st_mtime
#undef st_ctime

  dst->st_dev = (uint64_t)src->st_dev;
  dst->st_ino = (uint64_t)src->st_ino;
  dst->st_mode = (uint32_t)src->st_mode;
  dst->st_nlink = (uint32_t)src->st_nlink;
  dst->st_uid = (uint32_t)src->st_uid;
  dst->st_gid = (uint32_t)src->st_gid;
  dst->st_rdev = (uint64_t)src->st_rdev;
  dst->st_size = (int64_t)src->st_size;
  dst->st_atime = (int64_t)atime_val;
  dst->st_mtime = (int64_t)mtime_val;
  dst->st_ctime = (int64_t)ctime_val;
  dst->st_blksize = 512;
  dst->st_blocks = (dst->st_size + 511) / 512;
}

/* --- file metadata ------------------------------------------------------ */

int
mrb_hal_io_stat(mrb_state *mrb, const char *path, mrb_io_stat *st)
{
  struct stat s;
  (void)mrb;
  if (stat(path, &s) == -1) return -1;
  convert_stat(&s, st);
  return 0;
}

int
mrb_hal_io_fstat(mrb_state *mrb, int fd, mrb_io_stat *st)
{
  struct stat s;
  (void)mrb;
  if (fstat(fd, &s) == -1) return -1;
  convert_stat(&s, st);
  return 0;
}

int
mrb_hal_io_lstat(mrb_state *mrb, const char *path, mrb_io_stat *st)
{
  struct stat s;
  (void)mrb;
  /* wasi-libc has lstat (path_filestat_get with no follow). */
  if (lstat(path, &s) == -1) return -1;
  convert_stat(&s, st);
  return 0;
}

int
mrb_hal_io_chmod(mrb_state *mrb, const char *path, uint32_t mode)
{
  /* wasi-libc has no chmod (WASI preview1 has no permission bits).
   * Return success so File.chmod() in Ruby is a no-op rather than an
   * error — same effective behaviour as a tmpfs without permission
   * support. Change to ENOSYS if strict reporting is preferred. */
  (void)mrb; (void)path; (void)mode;
  return 0;
}

uint32_t
mrb_hal_io_umask(mrb_state *mrb, int32_t mask)
{
  /* No umask concept under WASI — always report 0. */
  (void)mrb; (void)mask;
  return 0;
}

int
mrb_hal_io_ftruncate(mrb_state *mrb, int fd, int64_t length)
{
  (void)mrb;
  return ftruncate(fd, (off_t)length);
}

int
mrb_hal_io_flock(mrb_state *mrb, int fd, int operation)
{
  /* WASI preview1 lacks flock-style advisory locks. */
  (void)mrb; (void)fd; (void)operation;
  errno = ENOSYS;
  return -1;
}

int
mrb_hal_io_unlink(mrb_state *mrb, const char *path)
{
  (void)mrb;
  return unlink(path);
}

int
mrb_hal_io_rename(mrb_state *mrb, const char *oldpath, const char *newpath)
{
  (void)mrb;
  return rename(oldpath, newpath);
}

int
mrb_hal_io_symlink(mrb_state *mrb, const char *target, const char *linkpath)
{
  (void)mrb;
  return symlink(target, linkpath);
}

int64_t
mrb_hal_io_readlink(mrb_state *mrb, const char *path, char *buf, size_t bufsize)
{
  (void)mrb;
  return (int64_t)readlink(path, buf, bufsize);
}

char*
mrb_hal_io_realpath(mrb_state *mrb, const char *path, char *resolved)
{
  (void)mrb;
  return realpath(path, resolved);
}

char*
mrb_hal_io_getcwd(mrb_state *mrb, char *buf, size_t size)
{
  (void)mrb;
  /* wasi-libc returns "/" — no real cwd in preview1. Honest enough. */
  return getcwd(buf, size);
}

const char*
mrb_hal_io_getenv(mrb_state *mrb, const char *name)
{
  (void)mrb;
  return getenv(name);
}

const char*
mrb_hal_io_gethome(mrb_state *mrb, const char *username)
{
  (void)mrb;
  /* No passwd database under WASI. Honour HOME env var when no
   * username given; reject named lookups. */
  if (username == NULL || *username == '\0') {
    const char *home = getenv("HOME");
    if (home == NULL) {
      errno = ENOENT;
      return NULL;
    }
    return home;
  }
  errno = ENOSYS;
  return NULL;
}

/* --- core I/O ----------------------------------------------------------- */

int
mrb_hal_io_open(mrb_state *mrb, const char *path, int flags, uint32_t mode)
{
  (void)mrb;
  int fd = open(path, flags, (mode_t)mode);
  if (fd == -1) return -1;
  /* Best-effort close-on-exec for non-stdio fds. wasi-libc accepts
   * fcntl(F_SETFD, FD_CLOEXEC) but treats it as a no-op (no exec). */
#if defined(F_GETFD) && defined(F_SETFD) && defined(FD_CLOEXEC)
  if (fd > 2) {
    int fd_flags = fcntl(fd, F_GETFD);
    if (fd_flags != -1) fcntl(fd, F_SETFD, fd_flags | FD_CLOEXEC);
  }
#endif
  return fd;
}

int
mrb_hal_io_close(mrb_state *mrb, int fd)
{
  (void)mrb;
  return close(fd);
}

int64_t
mrb_hal_io_read(mrb_state *mrb, int fd, void *buf, size_t count)
{
  (void)mrb;
  return (int64_t)read(fd, buf, count);
}

int64_t
mrb_hal_io_write(mrb_state *mrb, int fd, const void *buf, size_t count)
{
  (void)mrb;
  return (int64_t)write(fd, buf, count);
}

int64_t
mrb_hal_io_lseek(mrb_state *mrb, int fd, int64_t offset, int whence)
{
  int posix_whence;
  (void)mrb;
  switch (whence) {
    case MRB_IO_SEEK_SET: posix_whence = SEEK_SET; break;
    case MRB_IO_SEEK_CUR: posix_whence = SEEK_CUR; break;
    case MRB_IO_SEEK_END: posix_whence = SEEK_END; break;
    default: errno = EINVAL; return -1;
  }
  return (int64_t)lseek(fd, (off_t)offset, posix_whence);
}

int
mrb_hal_io_dup(mrb_state *mrb, int fd)
{
  /* wasi-libc has no dup(). */
  (void)mrb; (void)fd;
  errno = ENOSYS;
  return -1;
}

int
mrb_hal_io_fcntl(mrb_state *mrb, int fd, int cmd, int arg)
{
  /* wasi-libc accepts F_GETFD/F_SETFD with FD_CLOEXEC and a few
   * F_GETFL/F_SETFL flags; pass through and let it decide. */
  (void)mrb;
  return fcntl(fd, cmd, arg);
}

int
mrb_hal_io_isatty(mrb_state *mrb, int fd)
{
  (void)mrb;
  return isatty(fd) ? 1 : 0;
}

int
mrb_hal_io_pipe(mrb_state *mrb, int fds[2])
{
  /* wasi-libc has no pipe() — anonymous pipes aren't in WASI preview1. */
  (void)mrb; (void)fds;
  errno = ENOSYS;
  return -1;
}

/* --- process operations (all stubbed under WASI) ----------------------- */

int
mrb_hal_io_spawn_process(mrb_state *mrb, const char *cmd,
                         int stdin_fd, int stdout_fd, int stderr_fd,
                         int *pid)
{
  /* No fork/exec in WASI preview1. */
  (void)mrb; (void)cmd; (void)stdin_fd; (void)stdout_fd; (void)stderr_fd; (void)pid;
  errno = ENOSYS;
  return -1;
}

int
mrb_hal_io_waitpid(mrb_state *mrb, int pid, int *status, int options)
{
  (void)mrb; (void)pid; (void)status; (void)options;
  errno = ENOSYS;
  return -1;
}

/* --- I/O multiplexing (stubbed; can be wired to poll_oneoff later) ---- */

struct mrb_io_fdset {
  int dummy;
};

mrb_io_fdset*
mrb_hal_io_fdset_alloc(mrb_state *mrb)
{
  return (mrb_io_fdset*)mrb_malloc(mrb, sizeof(mrb_io_fdset));
}

void
mrb_hal_io_fdset_free(mrb_state *mrb, mrb_io_fdset *fdset)
{
  if (fdset) mrb_free(mrb, fdset);
}

void
mrb_hal_io_fdset_zero(mrb_state *mrb, mrb_io_fdset *fdset)
{
  (void)mrb; (void)fdset;
}

void
mrb_hal_io_fdset_set(mrb_state *mrb, int fd, mrb_io_fdset *fdset)
{
  (void)mrb; (void)fd; (void)fdset;
}

int
mrb_hal_io_fdset_isset(mrb_state *mrb, int fd, mrb_io_fdset *fdset)
{
  (void)mrb; (void)fd; (void)fdset;
  return 0;
}

int
mrb_hal_io_select(mrb_state *mrb, int nfds,
                  mrb_io_fdset *readfds,
                  mrb_io_fdset *writefds,
                  mrb_io_fdset *errorfds,
                  mrb_io_timeval *timeout)
{
  /* TODO: wire to wasi_snapshot_preview1.poll_oneoff if a Ruby caller
   * needs IO.select. For now keep it as ENOSYS — kotoyomi-style
   * scripts and the CLI use cases don't exercise this path. */
  (void)mrb; (void)nfds; (void)readfds; (void)writefds; (void)errorfds; (void)timeout;
  errno = ENOSYS;
  return -1;
}

/* --- HAL init/final ---------------------------------------------------- */

void mrb_hal_io_init(mrb_state *mrb) { (void)mrb; }
void mrb_hal_io_final(mrb_state *mrb) { (void)mrb; }

/* --- gem hooks --------------------------------------------------------- */

void
mrb_hal_wasi_io_gem_init(mrb_state *mrb)
{
  (void)mrb;
}

void
mrb_hal_wasi_io_gem_final(mrb_state *mrb)
{
  (void)mrb;
}
