/* Empty stub for wasi-sysroot which lacks <pwd.h>.
 * mruby-io's file.c includes this header but never uses any of its symbols
 * (no struct passwd / getpwnam / getpwuid references), so an empty stub
 * is enough to compile. */
#ifndef _PWD_H_STUB
#define _PWD_H_STUB
#endif
