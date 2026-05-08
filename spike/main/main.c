/*
 * Minimal mruby driver. Opens an mruby state in `_start` and leaves it
 * alive — the JS host drives Ruby source loading via the
 * `js_bridge_eval_handle` export (see mrbgem/mruby-js-bridge/src/js_bridge.c).
 *
 * Replaces the more typical "mruby reads stdin / runs a SCRIPT" entry
 * with a minimal "boot the VM, then wait for JS-driven evals" pattern.
 *
 * Forwards argc/argv (which wasi-libc populates from WASI's args_get)
 * into Ruby's ARGV, so JS-side `args.push("--foo")` reaches Ruby code as
 * `ARGV[0] == "--foo"`. Skips argv[0] (program name) per Ruby convention.
 */

#include <stdio.h>
#include <mruby.h>
#include <mruby/array.h>
#include <mruby/string.h>
#include <mruby/variable.h>

int main(int argc, char **argv) {
  mrb_state *mrb = mrb_open();
  if (!mrb) { fprintf(stderr, "mrb_open failed\n"); return 1; }

  /* Populate ARGV (program name at argv[0] is skipped, like CRuby). */
  mrb_value argv_ary = mrb_ary_new(mrb);
  for (int i = 1; i < argc; i++) {
    mrb_ary_push(mrb, argv_ary, mrb_str_new_cstr(mrb, argv[i]));
  }
  mrb_define_global_const(mrb, "ARGV", argv_ary);

  /* mrb stays alive for callbacks/eval; never closed. */
  return 0;
}
