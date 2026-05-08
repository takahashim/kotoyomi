/*
 * mruby-wasi-dir: minimal Dir API for mruby on WASI preview1.
 *
 * Uses wasi-libc's POSIX <dirent.h> surface (opendir / readdir /
 * closedir / mkdir / rmdir / stat). wasi-libc translates those to
 * WASI imports — path_open(O_DIRECTORY), fd_readdir, fd_close,
 * path_create_directory, path_remove_directory, path_filestat_get —
 * which mruby-wasm-js's wasi-preview1.js implements. Any other
 * preview1-compatible host adapter should also work.
 *
 * Surface (mirrors CRuby's Dir for the methods we expose):
 *   Dir.entries(path)       -> Array<String>  (includes "." / "..")
 *   Dir.mkdir(path)         -> nil
 *   Dir.rmdir(path)         -> nil  (alias: delete, unlink)
 *   Dir.exist?(path)        -> bool (alias: exists?)
 *   Dir.foreach(path) { ... }                      [defined in mrblib]
 *
 * Out of scope: Dir.pwd / Dir.chdir (no cwd in WASI preview1),
 * Dir.glob / Dir.[] (needs fnmatch), telldir / seekdir / rewinddir
 * (low value before a real consumer surfaces).
 */

#include <mruby.h>
#include <mruby/array.h>
#include <mruby/string.h>
#include <mruby/error.h>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

static void
raise_errno(mrb_state *mrb, const char *op, const char *path) {
  mrb_raisef(mrb, E_RUNTIME_ERROR, "%s: %s: %s",
             op, path, strerror(errno));
}

static mrb_value
mrb_dir_entries(mrb_state *mrb, mrb_value self) {
  const char *path;
  mrb_get_args(mrb, "z", &path);
  DIR *d = opendir(path);
  if (!d) raise_errno(mrb, "Dir.entries", path);
  mrb_value ary = mrb_ary_new(mrb);
  struct dirent *ent;
  while ((ent = readdir(d)) != NULL) {
    mrb_ary_push(mrb, ary, mrb_str_new_cstr(mrb, ent->d_name));
  }
  closedir(d);
  return ary;
}

static mrb_value
mrb_dir_mkdir(mrb_state *mrb, mrb_value self) {
  const char *path;
  mrb_get_args(mrb, "z", &path);
  if (mkdir(path, 0777) != 0) raise_errno(mrb, "Dir.mkdir", path);
  return mrb_nil_value();
}

static mrb_value
mrb_dir_rmdir(mrb_state *mrb, mrb_value self) {
  const char *path;
  mrb_get_args(mrb, "z", &path);
  if (rmdir(path) != 0) raise_errno(mrb, "Dir.rmdir", path);
  return mrb_nil_value();
}

static mrb_value
mrb_dir_exist_p(mrb_state *mrb, mrb_value self) {
  const char *path;
  mrb_get_args(mrb, "z", &path);
  struct stat sb;
  if (stat(path, &sb) != 0) return mrb_false_value();
  return S_ISDIR(sb.st_mode) ? mrb_true_value() : mrb_false_value();
}

void
mrb_mruby_wasi_dir_gem_init(mrb_state *mrb) {
  struct RClass *dir = mrb_define_class(mrb, "Dir", mrb->object_class);
  mrb_define_class_method(mrb, dir, "entries", mrb_dir_entries, MRB_ARGS_REQ(1));
  mrb_define_class_method(mrb, dir, "mkdir",   mrb_dir_mkdir,   MRB_ARGS_REQ(1));
  mrb_define_class_method(mrb, dir, "rmdir",   mrb_dir_rmdir,   MRB_ARGS_REQ(1));
  mrb_define_class_method(mrb, dir, "exist?",  mrb_dir_exist_p, MRB_ARGS_REQ(1));
}

void
mrb_mruby_wasi_dir_gem_final(mrb_state *mrb) {
}
