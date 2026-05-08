/*
 * Internal header for mruby-wasm-js. Shared between object.c (data type
 * + JS::Error helpers), bridge.c (low-level primitives), and callback.c
 * (callback table + WASM exports + gem init).
 *
 * Declares the WASM imports satisfied by the JS host adapter, plus the
 * cross-TU globals/helpers that survive the split of the original
 * single-file implementation.
 */
#ifndef MRUBY_WASM_JS_IMPORTS_H
#define MRUBY_WASM_JS_IMPORTS_H

#include <mruby.h>
#include <mruby/data.h>

/* ---------- WASM imports (js.* — implemented in adapter.js) ---------- */

#define IMPORT(name) \
  __attribute__((import_module("js"), import_name(#name))) extern

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
 * a handle to the JS Error object (for property reads via js_get). */
IMPORT(js_take_error) int js_take_error(void);

/* Diagnostics: # of currently-allocated JS handles (alloc'd minus released). */
IMPORT(js_handle_count) int js_handle_count(void);

#undef IMPORT

/* ---------- Cross-TU globals (defined in callback.c) ---------- */

extern mrb_state *g_mrb;
extern mrb_value g_callback_table;
extern int g_next_callback_id;

/* ---------- Cross-TU globals (defined in object.c) ---------- */

extern mrb_value g_object_class_obj;
extern mrb_value g_error_class_obj;
extern const struct mrb_data_type js_object_type;

/* ---------- Internal helpers (defined in object.c) ---------- */

mrb_value wrap_handle(mrb_state *mrb, int handle);
void raise_if_js_error(mrb_state *mrb);

/* ---------- Internal helpers (defined in callback.c) ---------- */

void ensure_callback_table(mrb_state *mrb);

/* ---------- Per-file class/method registration ---------- */

void js_object_define(mrb_state *mrb, struct RClass *js);
void js_bridge_define(mrb_state *mrb, struct RClass *js);
void js_callback_define(mrb_state *mrb, struct RClass *js);

#endif /* MRUBY_WASM_JS_IMPORTS_H */
