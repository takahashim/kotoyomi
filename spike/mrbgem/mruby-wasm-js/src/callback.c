/*
 * Callback registry + WASM exports + gem init.
 *
 * The callback table is a Ruby Hash mapping callback_id → Proc. JS gets
 * a wrapper function (via js_make_callback) that fires `js_invoke_proc`
 * back into the wasm. We snapshot the mrb_state at gem_init so the
 * exports (which can't take an extra arg) can find it.
 */
#include "imports.h"
#include <stdio.h>
#include <string.h>
#include <stddef.h>
#include <stdint.h>
#include <wasi/api.h>
#include <mruby/array.h>
#include <mruby/hash.h>
#include <mruby/class.h>
#include <mruby/proc.h>
#include <mruby/string.h>
#include <mruby/throw.h>
#include <mruby/variable.h>

/* Globals owned here (declarations live in imports.h) */
mrb_state *g_mrb = NULL;
mrb_value g_callback_table; /* Ruby Hash, lazily created */
int g_next_callback_id = 1;

/* Lazily create the callback Hash and pin it from GC. */
void
ensure_callback_table(mrb_state *mrb) {
  if (mrb_hash_p(g_callback_table)) return;
  g_callback_table = mrb_hash_new(mrb);
  mrb_gc_register(mrb, g_callback_table);
}

/* JS._make_callback(proc) -> [handle, callback_id]
 *
 * Returns BOTH the JS wrapper handle (for passing to JS as a function)
 * AND the callback id (for later release via _release_callback). The
 * id is what the C-side callback_table is keyed by. Without exposing
 * it, callers can't free entries and the table grows monotonically. */
static mrb_value
mrb_js_make_callback(mrb_state *mrb, mrb_value self) {
  mrb_value proc;
  mrb_get_args(mrb, "o", &proc);
  ensure_callback_table(mrb);
  int id = g_next_callback_id++;
  mrb_hash_set(mrb, g_callback_table, mrb_fixnum_value(id), proc);
  int handle = js_make_callback(id);
  mrb_value pair = mrb_ary_new_capa(mrb, 2);
  mrb_ary_push(mrb, pair, mrb_fixnum_value(handle));
  mrb_ary_push(mrb, pair, mrb_fixnum_value(id));
  return pair;
}

/* JS._release_callback(callback_id) -> nil
 *
 * Removes the callback Proc from the C-side table so it (and anything
 * it closes over) can be GC'd. Idempotent: removing an already-released
 * id is a no-op. The JS-side wrapper function is NOT removed (it's held
 * by the JS engine's listener references); subsequent invocations of
 * the wrapper will look up an empty entry and return early. */
static mrb_value
mrb_js_release_callback(mrb_state *mrb, mrb_value self) {
  mrb_int id;
  mrb_get_args(mrb, "i", &id);
  if (mrb_hash_p(g_callback_table)) {
    mrb_hash_delete_key(mrb, g_callback_table, mrb_fixnum_value((int)id));
  }
  return mrb_nil_value();
}

/* JS._callback_count() -> int — # of currently-registered callbacks. */
static mrb_value
mrb_js_callback_count(mrb_state *mrb, mrb_value self) {
  if (!mrb_hash_p(g_callback_table)) return mrb_fixnum_value(0);
  return mrb_fixnum_value(mrb_hash_size(mrb, g_callback_table));
}

/* JS._handle_count() -> int — # of currently-allocated JS handles. */
static mrb_value
mrb_js_handle_count(mrb_state *mrb, mrb_value self) {
  return mrb_fixnum_value(js_handle_count());
}

void
js_callback_define(mrb_state *mrb, struct RClass *js) {
  mrb_define_module_function(mrb, js, "_make_callback", mrb_js_make_callback, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_release_callback", mrb_js_release_callback, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_callback_count", mrb_js_callback_count, MRB_ARGS_NONE());
  mrb_define_module_function(mrb, js, "_handle_count", mrb_js_handle_count, MRB_ARGS_NONE());
}

/* ---------- WASM exports ---------- */

/*
 * WASM export: JS calls this with a handle to a Ruby source string.
 * mruby loads/parses/executes it; on parse/runtime error, prints to
 * stderr and returns 1 (so the host can show an error).
 *
 * The source is wrapped in `JS.__run_in_fiber__ do ... end` so
 * that any `Value#await` inside has a Fiber to yield from. If the
 * fiber suspends (await fired), this function still returns 0 — the
 * fiber resumes asynchronously when the awaited Promise settles, via
 * the existing js_invoke_proc callback path.
 */
#define FIBER_PREAMBLE "::JS.__run_in_fiber__ do\n"
#define FIBER_POSTAMBLE "\nend\n"

__attribute__((export_name("js_eval_handle")))
int
js_eval_handle(int src_handle) {
  if (!g_mrb) return 1;
  mrb_state *mrb = g_mrb;
  int len = js_to_string_len(src_handle);
  if (len <= 0) return 0;

  size_t pre = sizeof(FIBER_PREAMBLE) - 1;
  size_t post = sizeof(FIBER_POSTAMBLE) - 1;
  char *buf = (char *)mrb_malloc(mrb, pre + (size_t)len + post + 1);
  memcpy(buf, FIBER_PREAMBLE, pre);
  js_to_string_copy(src_handle, buf + pre, len);
  memcpy(buf + pre + len, FIBER_POSTAMBLE, post);
  buf[pre + len + post] = '\0';

  mrb_load_string(mrb, buf);
  mrb_free(mrb, buf);
  if (mrb->exc) {
    mrb_print_error(mrb);
    mrb->exc = NULL;
    return 1;
  }
  return 0;
}

#undef FIBER_PREAMBLE
#undef FIBER_POSTAMBLE

/*
 * WASM export: invoked by the JS wrapper function when its callback fires.
 *
 * - callback_id: id assigned in mrb_js_make_callback
 * - args_handle: JS array of the actual call arguments
 *
 * Looks up the Ruby Proc, wraps each JS arg as a JS::Object, and yields.
 */
__attribute__((export_name("js_invoke_proc")))
int
js_invoke_proc(int callback_id, int args_handle) {
  if (!g_mrb || !mrb_hash_p(g_callback_table)) return 0;
  mrb_state *mrb = g_mrb;

  mrb_value proc = mrb_hash_get(mrb, g_callback_table, mrb_fixnum_value(callback_id));
  if (mrb_nil_p(proc)) return 0;

  /* Discover the number of args by reading args_handle.length */
  int length_h = js_get(args_handle, "length", 6);
  int n = js_to_int(length_h);
  js_release(length_h);

  /* Pull out each arg as a JS::Object. Index-as-string ("0", "1", ...) is
   * how JS exposes array elements via property access. */
  mrb_value *args = NULL;
  if (n > 0) {
    args = (mrb_value *)mrb_malloc(mrb, sizeof(mrb_value) * (size_t)n);
    for (int i = 0; i < n; i++) {
      char idx[16];
      int k = snprintf(idx, sizeof(idx), "%d", i);
      int item = js_get(args_handle, idx, k);
      args[i] = wrap_handle(mrb, item);
    }
  }

  /* Set up our own jmpbuf around the yield. Without this, an uncaught
   * Ruby exception inside the block would longjmp past the wasm export
   * boundary (`unreachable` in __wasm_setjmp_test) and crash the host. */
  struct mrb_jmpbuf c_jmp;
  struct mrb_jmpbuf *prev_jmp = mrb->jmp;
  mrb->jmp = &c_jmp;
  MRB_TRY(&c_jmp) {
    mrb_yield_argv(mrb, proc, n, args);
    mrb->jmp = prev_jmp;
  } MRB_CATCH(&c_jmp) {
    mrb->jmp = prev_jmp;
    mrb_print_error(mrb);
    mrb->exc = NULL;
  } MRB_END_EXC(&c_jmp);

  if (args) mrb_free(mrb, args);
  return 0;
}

/* ---------- Gem init / final ---------- */

void
mrb_mruby_wasm_js_gem_init(mrb_state *mrb) {
  g_mrb = mrb;
  g_callback_table = mrb_nil_value();

  struct RClass *js = mrb_define_module(mrb, "JS");

  js_object_define(mrb, js);
  js_bridge_define(mrb, js);
  js_callback_define(mrb, js);
}

void
mrb_mruby_wasm_js_gem_final(mrb_state *mrb) {
  /* Per-instance handles are released by mruby GC via js_object_free.
     Anything still alive at mrb_close gets freed during final GC sweep. */
}

/* ---------- Reactor boot ---------- */

/* Read WASI args via __wasi_args_get and define them as ARGV (skipping
 * argv[0] = program name, matching Ruby/CRuby convention). Called from
 * boot_mruby below once mrb_open has set g_mrb. Failure to read args
 * (no args supplied, allocation fail) just leaves ARGV empty — the
 * caller can still proceed. */
static void
populate_argv(mrb_state *mrb) {
  size_t argc = 0, argv_buf_size = 0;
  if (__wasi_args_sizes_get(&argc, &argv_buf_size) != 0) return;

  mrb_value ary = mrb_ary_new(mrb);
  mrb_define_global_const(mrb, "ARGV", ary);
  if (argc == 0) return;

  uint8_t **argv = (uint8_t **)mrb_malloc(mrb, sizeof(uint8_t *) * argc);
  uint8_t *argv_buf = (uint8_t *)mrb_malloc(mrb, argv_buf_size);
  if (__wasi_args_get(argv, argv_buf) == 0) {
    /* Skip argv[0] (program name), like CRuby's ARGV. */
    for (size_t i = 1; i < argc; i++) {
      mrb_ary_push(mrb, ary, mrb_str_new_cstr(mrb, (const char *)argv[i]));
    }
  }
  mrb_free(mrb, argv);
  mrb_free(mrb, argv_buf);
}

/* Reactor entry point: __wasm_call_ctors (run by `_initialize`) invokes
 * this. Brings up the mruby VM, runs all gem_init hooks (ours sets
 * g_mrb), and pulls argv from WASI into Ruby's ARGV.
 *
 * The mrb_state stays alive for the lifetime of the wasm instance — we
 * never call mrb_close. Heap-allocated state survives across subsequent
 * export calls (js_eval_handle, js_invoke_proc) since wasm linear memory
 * persists per-instance. */
__attribute__((constructor))
static void
boot_mruby(void) {
  mrb_state *mrb = mrb_open();
  if (!mrb) return;
  /* mrb_open already invoked mrb_mruby_wasm_js_gem_init, so g_mrb is set. */
  populate_argv(mrb);
}
