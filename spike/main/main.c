/*
 * Phase 2d entry point.
 *
 * Open mruby in `_start` and leave it alive; the JS side drives Ruby
 * source loading via the `kotoyomi_eval_handle` export. Lets us load
 * a kotoyomi app's lib .rb files at boot time instead of hardcoding SCRIPT.
 */

#include <stdio.h>
#include <mruby.h>

int main(void) {
  mrb_state *mrb = mrb_open();
  if (!mrb) { fprintf(stderr, "mrb_open failed\n"); return 1; }
  /* mrb stays alive for callbacks/eval; never closed. */
  return 0;
}
