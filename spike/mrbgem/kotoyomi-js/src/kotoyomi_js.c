/*
 * kotoyomi-js: JS bridge for mruby (Phase 2a + auto-release + callbacks)
 *
 * Kotoyomi::JS::Value is a C-backed (MRB_TT_DATA) class. Each instance
 * owns a JS handle; when the Ruby object is collected by mruby's GC,
 * the free callback releases the JS handle automatically.
 *
 * Ruby blocks/procs can be passed as JS callbacks via JS.callback(&block).
 * The block is registered in a callback table (kept alive across calls)
 * and a JS wrapper function is created on the host side. When the wrapper
 * fires, JS calls back into mruby via the `kotoyomi_invoke_proc` export.
 *
 * Underscore-prefixed module functions on Kotoyomi::JS are low-level
 * primitives that operate on raw integer handles. The Ruby-friendly
 * API lives in mrblib/kotoyomi_js.rb.
 */

#include <mruby.h>
#include <mruby/string.h>
#include <mruby/array.h>
#include <mruby/hash.h>
#include <mruby/data.h>
#include <mruby/class.h>
#include <mruby/proc.h>
#include <mruby/throw.h>

/* ---------- WASM imports (kotoyomi.* — implemented in adapter.js) ---------- */

#define IMPORT(name) \
  __attribute__((import_module("kotoyomi"), import_name(#name))) extern

IMPORT(js_eval) int js_eval(const char *src, int len);
IMPORT(js_global) int js_global(void);
IMPORT(js_release) void js_release(int handle);
IMPORT(js_get) int js_get(int handle, const char *key, int key_len);
IMPORT(js_set) void js_set(int handle, const char *key, int key_len, int value_handle);
IMPORT(js_call) int js_call(int handle, const char *method, int method_len,
                            const int *args, int arg_count);
IMPORT(js_to_string_len) int js_to_string_len(int handle);
IMPORT(js_to_string_copy) void js_to_string_copy(int handle, char *buf, int buf_len);
IMPORT(js_from_string) int js_from_string(const char *s, int len);
IMPORT(js_to_int) int js_to_int(int handle);
IMPORT(js_from_int) int js_from_int(int value);
IMPORT(js_to_float) double js_to_float(int handle);
IMPORT(js_from_float) int js_from_float(double value);
IMPORT(js_is_null) int js_is_null(int handle);
IMPORT(js_make_callback) int js_make_callback(int callback_id);

#undef IMPORT

/* ---------- Static state for callback dispatch ---------- */

static mrb_state *g_mrb = NULL;
static mrb_value g_callback_table; /* Ruby Hash, lazily created */
static mrb_value g_value_class_obj; /* cached Kotoyomi::JS::Value */
static int g_next_callback_id = 1;

/* ---------- Kotoyomi::JS::Value (data type) ---------- */

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
  "Kotoyomi::JS::Value",
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

/* Helper: wrap an int handle as a Kotoyomi::JS::Value object. */
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
  return mrb_fixnum_value(js_eval(src, (int)len));
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
  return mrb_fixnum_value(js_get((int)handle, key, (int)key_len));
}

static mrb_value
mrb_js_set(mrb_state *mrb, mrb_value self) {
  mrb_int handle;
  const char *key;
  mrb_int key_len;
  mrb_int value_handle;
  mrb_get_args(mrb, "isi", &handle, &key, &key_len, &value_handle);
  js_set((int)handle, key, (int)key_len, (int)value_handle);
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

/* ---------- Callback registration & dispatch ---------- */

/* Lazily create the callback Hash and pin it from GC. */
static void
ensure_callback_table(mrb_state *mrb) {
  if (mrb_hash_p(g_callback_table)) return;
  g_callback_table = mrb_hash_new(mrb);
  mrb_gc_register(mrb, g_callback_table);
}

/* Kotoyomi::JS._make_callback(proc) -> int handle (for the JS wrapper) */
static mrb_value
mrb_js_make_callback(mrb_state *mrb, mrb_value self) {
  mrb_value proc;
  mrb_get_args(mrb, "o", &proc);
  ensure_callback_table(mrb);
  int id = g_next_callback_id++;
  mrb_hash_set(mrb, g_callback_table, mrb_fixnum_value(id), proc);
  int handle = js_make_callback(id);
  return mrb_fixnum_value(handle);
}

/*
 * WASM export: invoked by the JS wrapper function when its callback fires.
 *
 * - callback_id: id assigned in mrb_js_make_callback
 * - args_handle: JS array of the actual call arguments
 *
 * Looks up the Ruby Proc, wraps each JS arg as a Value, and yields.
 */
/*
 * WASM export: JS calls this with a handle to a Ruby source string.
 * mruby loads/parses/executes it; on parse/runtime error, prints to
 * stderr and returns 1 (so the host can show an error).
 *
 * Lets us boot mruby once at _start and then load .rb files lazily
 * from JS, instead of embedding a single hardcoded SCRIPT in main.c.
 */
__attribute__((export_name("kotoyomi_eval_handle")))
int
kotoyomi_eval_handle(int src_handle) {
  if (!g_mrb) return 1;
  mrb_state *mrb = g_mrb;
  int len = js_to_string_len(src_handle);
  if (len <= 0) return 0;
  char *buf = (char *)mrb_malloc(mrb, (size_t)len + 1);
  js_to_string_copy(src_handle, buf, len);
  buf[len] = '\0';
  mrb_load_string(mrb, buf);
  mrb_free(mrb, buf);
  if (mrb->exc) {
    mrb_print_error(mrb);
    mrb->exc = NULL;
    return 1;
  }
  return 0;
}

__attribute__((export_name("kotoyomi_invoke_proc")))
int
kotoyomi_invoke_proc(int callback_id, int args_handle) {
  if (!g_mrb || !mrb_hash_p(g_callback_table)) return 0;
  mrb_state *mrb = g_mrb;

  mrb_value proc = mrb_hash_get(mrb, g_callback_table, mrb_fixnum_value(callback_id));
  if (mrb_nil_p(proc)) return 0;

  /* Discover the number of args by reading args_handle.length */
  int length_h = js_get(args_handle, "length", 6);
  int n = js_to_int(length_h);
  js_release(length_h);

  /* Pull out each arg as a Value */
  mrb_value *args = NULL;
  if (n > 0) {
    args = (mrb_value *)mrb_malloc(mrb, sizeof(mrb_value) * (size_t)n);
    for (int i = 0; i < n; i++) {
      char idx[16];
      int k = 0;
      int x = i;
      char tmp[16];
      do { tmp[k++] = '0' + (x % 10); x /= 10; } while (x > 0);
      for (int j = 0; j < k; j++) idx[j] = tmp[k - 1 - j];
      idx[k] = '\0';
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
mrb_kotoyomi_js_gem_init(mrb_state *mrb) {
  g_mrb = mrb;
  g_callback_table = mrb_nil_value();

  struct RClass *kotoyomi = mrb_define_module(mrb, "Kotoyomi");
  struct RClass *js = mrb_define_module_under(mrb, kotoyomi, "JS");

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

  /* Low-level primitives. The Ruby-side wrapper is in mrblib/kotoyomi_js.rb. */
  mrb_define_module_function(mrb, js, "_eval", mrb_js_eval, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_global", mrb_js_global, MRB_ARGS_NONE());
  mrb_define_module_function(mrb, js, "_release", mrb_js_release, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_get", mrb_js_get, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, js, "_set", mrb_js_set, MRB_ARGS_REQ(3));
  mrb_define_module_function(mrb, js, "_call", mrb_js_call, MRB_ARGS_REQ(3));
  mrb_define_module_function(mrb, js, "_to_string", mrb_js_to_string, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_from_string", mrb_js_from_string, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_to_int", mrb_js_to_int, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_from_int", mrb_js_from_int, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_to_float", mrb_js_to_float, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_from_float", mrb_js_from_float, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_is_null", mrb_js_is_null, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_make_callback", mrb_js_make_callback, MRB_ARGS_REQ(1));
}

void
mrb_kotoyomi_js_gem_final(mrb_state *mrb) {
  /* Per-Value handles are released by mruby GC via js_value_free.
     Anything still alive at mrb_close gets freed during final GC sweep. */
}
