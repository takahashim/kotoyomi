/*
 * mruby-js-bridge: minimal mruby ↔ JavaScript bridge for WASM hosts.
 *
 * JSBridge::Value is a C-backed (MRB_TT_DATA) class. Each instance owns
 * a JS handle; when the Ruby object is collected by mruby's GC, the
 * free callback releases the JS handle automatically.
 *
 * Ruby blocks/procs can be passed as JS callbacks via JSBridge.callback(&block).
 * The block is registered in a callback table (kept alive across calls)
 * and a JS wrapper function is created on the host side. When the wrapper
 * fires, JS calls back into mruby via the `js_bridge_invoke_proc` export.
 *
 * Underscore-prefixed module functions on JSBridge are low-level primitives
 * that operate on raw integer handles. The Ruby-friendly API lives in
 * mrblib/js_bridge.rb.
 */

#include <mruby.h>
#include <stdio.h>
#include <string.h>
#include <mruby/string.h>
#include <mruby/array.h>
#include <mruby/hash.h>
#include <mruby/data.h>
#include <mruby/class.h>
#include <mruby/proc.h>
#include <mruby/throw.h>
#include <mruby/variable.h>

/* ---------- WASM imports (js_bridge.* — implemented in adapter.js) ---------- */

#define IMPORT(name) \
  __attribute__((import_module("js_bridge"), import_name(#name))) extern

IMPORT(js_eval) int js_eval(const char *src, int len);
IMPORT(js_global) int js_global(void);
IMPORT(js_release) void js_release(int handle);
IMPORT(js_get) int js_get(int handle, const char *key, int key_len);
IMPORT(js_set) void js_set(int handle, const char *key, int key_len, int value_handle);
IMPORT(js_call) int js_call(int handle, const char *method, int method_len,
                            const int *args, int arg_count);
IMPORT(js_new) int js_new(int handle, const int *args, int arg_count);
IMPORT(js_to_string_len) int js_to_string_len(int handle);
IMPORT(js_to_string_copy) void js_to_string_copy(int handle, char *buf, int buf_len);
IMPORT(js_from_string) int js_from_string(const char *s, int len);
IMPORT(js_to_int) int js_to_int(int handle);
IMPORT(js_from_int) int js_from_int(int value);
IMPORT(js_to_float) double js_to_float(int handle);
IMPORT(js_from_float) int js_from_float(double value);
IMPORT(js_is_null) int js_is_null(int handle);
IMPORT(js_strict_equal) int js_strict_equal(int a, int b);
IMPORT(js_typeof_len) int js_typeof_len(int handle);
IMPORT(js_typeof_copy) void js_typeof_copy(int handle, char *buf, int buf_len);
IMPORT(js_inspect_len) int js_inspect_len(int handle);
IMPORT(js_inspect_copy) void js_inspect_copy(int handle, char *buf, int buf_len);
IMPORT(js_instanceof) int js_instanceof(int instance, int constructor);
IMPORT(js_make_callback) int js_make_callback(int callback_id);

/* Last JS exception caught by adapter. 0 means no error pending; otherwise
 * a handle to a string with the JS error's `.message` (or stringification). */
IMPORT(js_take_error) int js_take_error(void);

/* Diagnostics: # of currently-allocated JS handles (alloc'd minus released).
 * Used by JSBridge.stats so callers can spot leaks. */
IMPORT(js_handle_count) int js_handle_count(void);

#undef IMPORT

/* ---------- Static state for callback dispatch ---------- */

static mrb_state *g_mrb = NULL;
static mrb_value g_callback_table; /* Ruby Hash, lazily created */
static mrb_value g_value_class_obj; /* cached JSBridge::Value */
static mrb_value g_error_class_obj; /* cached JSBridge::Error */
static int g_next_callback_id = 1;

/* Forward declaration — defined after the Value class section. */
static mrb_value wrap_handle(mrb_state *mrb, int handle);

/* Read the JS Error object's `.message` property as an mrb String. */
static mrb_value
extract_error_message(mrb_state *mrb, int err_h) {
  int msg_h = js_get(err_h, "message", 7);
  int len = js_to_string_len(msg_h);
  mrb_value msg;
  if (len <= 0) {
    msg = mrb_str_new_lit(mrb, "JS error");
  } else {
    char *buf = (char *)mrb_malloc(mrb, (size_t)len);
    js_to_string_copy(msg_h, buf, len);
    msg = mrb_str_new(mrb, buf, len);
    mrb_free(mrb, buf);
  }
  js_release(msg_h);
  return msg;
}

/* If the JS adapter has stashed an error from the most recent js_call /
 * js_new / js_eval, raise JSBridge::Error with the JS Error's `.message`
 * as the Ruby exception message AND the original JS Error attached as
 * @js_value (so users can read .name / .stack / .cause / etc. from
 * Ruby). Called at the end of each primitive that can dispatch to JS. */
static void
raise_if_js_error(mrb_state *mrb) {
  int err_h = js_take_error();
  if (err_h == 0) return;

  mrb_value msg = extract_error_message(mrb, err_h);
  /* wrap_handle takes ownership: Value's GC free callback will release. */
  mrb_value js_err_value = wrap_handle(mrb, err_h);

  /* Construct JSBridge::Error.new(msg) and attach @js_value. */
  mrb_value exc = mrb_funcall(mrb, g_error_class_obj, "new", 1, msg);
  mrb_iv_set(mrb, exc, mrb_intern_lit(mrb, "@js_value"), js_err_value);
  mrb_exc_raise(mrb, exc);
}

/* ---------- JSBridge::Value (data type) ---------- */

typedef struct {
  int handle;
} js_value_t;

static void
js_value_free(mrb_state *mrb, void *ptr) {
  if (ptr) {
    js_value_t *v = (js_value_t *)ptr;
    if (v->handle != 0) {
      js_release(v->handle);
    }
    mrb_free(mrb, v);
  }
}

static const struct mrb_data_type js_value_type = {
  "JSBridge::Value",
  js_value_free,
};

static mrb_value
mrb_js_value_init(mrb_state *mrb, mrb_value self) {
  mrb_int handle;
  mrb_get_args(mrb, "i", &handle);
  js_value_t *v = (js_value_t *)mrb_malloc(mrb, sizeof(*v));
  v->handle = (int)handle;
  mrb_data_init(self, v, &js_value_type);
  return self;
}

static mrb_value
mrb_js_value_handle(mrb_state *mrb, mrb_value self) {
  js_value_t *v = (js_value_t *)mrb_data_get_ptr(mrb, self, &js_value_type);
  return mrb_fixnum_value(v->handle);
}

/* Helper: wrap an int handle as a JSBridge::Value object. */
static mrb_value
wrap_handle(mrb_state *mrb, int handle) {
  mrb_value handle_val = mrb_fixnum_value(handle);
  return mrb_obj_new(mrb, mrb_class_ptr(g_value_class_obj), 1, &handle_val);
}

/* ---------- Module-level low-level primitives ---------- */

static mrb_value
mrb_js_eval(mrb_state *mrb, mrb_value self) {
  const char *src;
  mrb_int len;
  mrb_get_args(mrb, "s", &src, &len);
  int handle = js_eval(src, (int)len);
  raise_if_js_error(mrb);
  return mrb_fixnum_value(handle);
}

static mrb_value
mrb_js_global(mrb_state *mrb, mrb_value self) {
  return mrb_fixnum_value(js_global());
}

static mrb_value
mrb_js_release(mrb_state *mrb, mrb_value self) {
  mrb_int handle;
  mrb_get_args(mrb, "i", &handle);
  js_release((int)handle);
  return mrb_nil_value();
}

static mrb_value
mrb_js_get(mrb_state *mrb, mrb_value self) {
  mrb_int handle;
  const char *key;
  mrb_int key_len;
  mrb_get_args(mrb, "is", &handle, &key, &key_len);
  int result = js_get((int)handle, key, (int)key_len);
  raise_if_js_error(mrb);
  return mrb_fixnum_value(result);
}

static mrb_value
mrb_js_set(mrb_state *mrb, mrb_value self) {
  mrb_int handle;
  const char *key;
  mrb_int key_len;
  mrb_int value_handle;
  mrb_get_args(mrb, "isi", &handle, &key, &key_len, &value_handle);
  js_set((int)handle, key, (int)key_len, (int)value_handle);
  raise_if_js_error(mrb);
  return mrb_nil_value();
}

static mrb_value
mrb_js_call(mrb_state *mrb, mrb_value self) {
  mrb_int handle;
  const char *method;
  mrb_int method_len;
  mrb_value args_ary;
  mrb_get_args(mrb, "isA", &handle, &method, &method_len, &args_ary);

  mrb_int n = RARRAY_LEN(args_ary);
  int *args = NULL;
  if (n > 0) {
    args = (int *)mrb_malloc(mrb, sizeof(int) * (size_t)n);
    for (mrb_int i = 0; i < n; i++) {
      args[i] = (int)mrb_integer(mrb_ary_ref(mrb, args_ary, i));
    }
  }
  int result = js_call((int)handle, method, (int)method_len, args, (int)n);
  if (args) mrb_free(mrb, args);
  raise_if_js_error(mrb);
  return mrb_fixnum_value(result);
}

static mrb_value
mrb_js_new(mrb_state *mrb, mrb_value self) {
  mrb_int handle;
  mrb_value args_ary;
  mrb_get_args(mrb, "iA", &handle, &args_ary);

  mrb_int n = RARRAY_LEN(args_ary);
  int *args = NULL;
  if (n > 0) {
    args = (int *)mrb_malloc(mrb, sizeof(int) * (size_t)n);
    for (mrb_int i = 0; i < n; i++) {
      args[i] = (int)mrb_integer(mrb_ary_ref(mrb, args_ary, i));
    }
  }
  int result = js_new((int)handle, args, (int)n);
  if (args) mrb_free(mrb, args);
  raise_if_js_error(mrb);
  return mrb_fixnum_value(result);
}

static mrb_value
mrb_js_to_string(mrb_state *mrb, mrb_value self) {
  mrb_int handle;
  mrb_get_args(mrb, "i", &handle);
  int len = js_to_string_len((int)handle);
  if (len <= 0) return mrb_str_new_lit(mrb, "");
  char *buf = (char *)mrb_malloc(mrb, (size_t)len);
  js_to_string_copy((int)handle, buf, len);
  mrb_value result = mrb_str_new(mrb, buf, len);
  mrb_free(mrb, buf);
  return result;
}

static mrb_value
mrb_js_from_string(mrb_state *mrb, mrb_value self) {
  const char *s;
  mrb_int len;
  mrb_get_args(mrb, "s", &s, &len);
  return mrb_fixnum_value(js_from_string(s, (int)len));
}

static mrb_value
mrb_js_to_int(mrb_state *mrb, mrb_value self) {
  mrb_int handle;
  mrb_get_args(mrb, "i", &handle);
  return mrb_fixnum_value(js_to_int((int)handle));
}

static mrb_value
mrb_js_from_int(mrb_state *mrb, mrb_value self) {
  mrb_int value;
  mrb_get_args(mrb, "i", &value);
  return mrb_fixnum_value(js_from_int((int)value));
}

static mrb_value
mrb_js_to_float(mrb_state *mrb, mrb_value self) {
  mrb_int handle;
  mrb_get_args(mrb, "i", &handle);
  return mrb_float_value(mrb, (mrb_float)js_to_float((int)handle));
}

static mrb_value
mrb_js_from_float(mrb_state *mrb, mrb_value self) {
  mrb_float value;
  mrb_get_args(mrb, "f", &value);
  return mrb_fixnum_value(js_from_float((double)value));
}

static mrb_value
mrb_js_is_null(mrb_state *mrb, mrb_value self) {
  mrb_int handle;
  mrb_get_args(mrb, "i", &handle);
  return mrb_bool_value(js_is_null((int)handle) != 0);
}

static mrb_value
mrb_js_strict_equal(mrb_state *mrb, mrb_value self) {
  mrb_int a, b;
  mrb_get_args(mrb, "ii", &a, &b);
  return mrb_bool_value(js_strict_equal((int)a, (int)b) != 0);
}

static mrb_value
mrb_js_typeof(mrb_state *mrb, mrb_value self) {
  mrb_int handle;
  mrb_get_args(mrb, "i", &handle);
  int len = js_typeof_len((int)handle);
  if (len <= 0) return mrb_str_new_lit(mrb, "");
  char *buf = (char *)mrb_malloc(mrb, (size_t)len);
  js_typeof_copy((int)handle, buf, len);
  mrb_value result = mrb_str_new(mrb, buf, len);
  mrb_free(mrb, buf);
  return result;
}

static mrb_value
mrb_js_inspect(mrb_state *mrb, mrb_value self) {
  mrb_int handle;
  mrb_get_args(mrb, "i", &handle);
  int len = js_inspect_len((int)handle);
  if (len <= 0) return mrb_str_new_lit(mrb, "");
  char *buf = (char *)mrb_malloc(mrb, (size_t)len);
  js_inspect_copy((int)handle, buf, len);
  mrb_value result = mrb_str_new(mrb, buf, len);
  mrb_free(mrb, buf);
  return result;
}

static mrb_value
mrb_js_instanceof(mrb_state *mrb, mrb_value self) {
  mrb_int instance, ctor;
  mrb_get_args(mrb, "ii", &instance, &ctor);
  return mrb_bool_value(js_instanceof((int)instance, (int)ctor) != 0);
}

/* ---------- Callback registration & dispatch ---------- */

/* Lazily create the callback Hash and pin it from GC. */
static void
ensure_callback_table(mrb_state *mrb) {
  if (mrb_hash_p(g_callback_table)) return;
  g_callback_table = mrb_hash_new(mrb);
  mrb_gc_register(mrb, g_callback_table);
}

/* JSBridge._make_callback(proc) -> [handle, callback_id]
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

/* JSBridge._release_callback(callback_id) -> nil
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

/* JSBridge._callback_count() -> int — # of currently-registered callbacks. */
static mrb_value
mrb_js_callback_count(mrb_state *mrb, mrb_value self) {
  if (!mrb_hash_p(g_callback_table)) return mrb_fixnum_value(0);
  return mrb_fixnum_value(mrb_hash_size(mrb, g_callback_table));
}

/* JSBridge._handle_count() -> int — # of currently-allocated JS handles. */
static mrb_value
mrb_js_handle_count(mrb_state *mrb, mrb_value self) {
  return mrb_fixnum_value(js_handle_count());
}

/*
 * WASM export: JS calls this with a handle to a Ruby source string.
 * mruby loads/parses/executes it; on parse/runtime error, prints to
 * stderr and returns 1 (so the host can show an error).
 *
 * The source is wrapped in `JSBridge.__run_in_fiber__ do ... end` so
 * that any `Value#await` inside has a Fiber to yield from. If the
 * fiber suspends (await fired), this function still returns 0 — the
 * fiber resumes asynchronously when the awaited Promise settles, via
 * the existing js_bridge_invoke_proc callback path.
 */
#define FIBER_PREAMBLE "::JSBridge.__run_in_fiber__ do\n"
#define FIBER_POSTAMBLE "\nend\n"

__attribute__((export_name("js_bridge_eval_handle")))
int
js_bridge_eval_handle(int src_handle) {
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
 * Looks up the Ruby Proc, wraps each JS arg as a Value, and yields.
 */
__attribute__((export_name("js_bridge_invoke_proc")))
int
js_bridge_invoke_proc(int callback_id, int args_handle) {
  if (!g_mrb || !mrb_hash_p(g_callback_table)) return 0;
  mrb_state *mrb = g_mrb;

  mrb_value proc = mrb_hash_get(mrb, g_callback_table, mrb_fixnum_value(callback_id));
  if (mrb_nil_p(proc)) return 0;

  /* Discover the number of args by reading args_handle.length */
  int length_h = js_get(args_handle, "length", 6);
  int n = js_to_int(length_h);
  js_release(length_h);

  /* Pull out each arg as a Value. Index-as-string ("0", "1", ...) is
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

/* ---------- Gem init ---------- */

void
mrb_mruby_js_bridge_gem_init(mrb_state *mrb) {
  g_mrb = mrb;
  g_callback_table = mrb_nil_value();

  struct RClass *js = mrb_define_module(mrb, "JSBridge");

  /* JSBridge::Error < StandardError — raised when a JS call throws. */
  struct RClass *err_cls = mrb_define_class_under(
    mrb, js, "Error", mrb_class_get(mrb, "StandardError"));
  g_error_class_obj = mrb_obj_value(err_cls);
  mrb_gc_register(mrb, g_error_class_obj);

  /* Value class — BasicObject subclass so method_missing forwards almost
     everything to JS without colliding with Object's methods (then, tap,
     itself, ==, inspect, ...). Matches ruby.wasm's JS::Object design. */
  struct RClass *basic_object = mrb_class_get(mrb, "BasicObject");
  struct RClass *value = mrb_define_class_under(mrb, js, "Value", basic_object);
  MRB_SET_INSTANCE_TT(value, MRB_TT_DATA);
  mrb_define_method(mrb, value, "initialize", mrb_js_value_init, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, value, "handle", mrb_js_value_handle, MRB_ARGS_NONE());
  g_value_class_obj = mrb_obj_value(value);
  mrb_gc_register(mrb, g_value_class_obj);

  /* Low-level primitives. The Ruby-side wrapper is in mrblib/js_bridge.rb. */
  mrb_define_module_function(mrb, js, "_eval", mrb_js_eval, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_global", mrb_js_global, MRB_ARGS_NONE());
  mrb_define_module_function(mrb, js, "_release", mrb_js_release, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_get", mrb_js_get, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, js, "_set", mrb_js_set, MRB_ARGS_REQ(3));
  mrb_define_module_function(mrb, js, "_call", mrb_js_call, MRB_ARGS_REQ(3));
  mrb_define_module_function(mrb, js, "_new", mrb_js_new, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, js, "_to_string", mrb_js_to_string, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_from_string", mrb_js_from_string, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_to_int", mrb_js_to_int, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_from_int", mrb_js_from_int, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_to_float", mrb_js_to_float, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_from_float", mrb_js_from_float, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_is_null", mrb_js_is_null, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_strict_equal", mrb_js_strict_equal, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, js, "_typeof", mrb_js_typeof, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_inspect", mrb_js_inspect, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_instanceof", mrb_js_instanceof, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, js, "_make_callback", mrb_js_make_callback, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_release_callback", mrb_js_release_callback, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_callback_count", mrb_js_callback_count, MRB_ARGS_NONE());
  mrb_define_module_function(mrb, js, "_handle_count", mrb_js_handle_count, MRB_ARGS_NONE());
}

void
mrb_mruby_js_bridge_gem_final(mrb_state *mrb) {
  /* Per-Value handles are released by mruby GC via js_value_free.
     Anything still alive at mrb_close gets freed during final GC sweep. */
}
