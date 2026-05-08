/*
 * Low-level primitives exposed as `JS._eval`, `JS._global`, `JS._get`,
 * `JS._set`, `JS._call`, `JS._new`, `JS._to_string`, etc. These are 1:1
 * with the WASM imports and operate on raw integer handles. The
 * Ruby-friendly API (JS.global / JS.eval / JS::Object#[] / ...) lives in
 * mrblib/js.rb and calls down to these.
 */
#include "imports.h"
#include <mruby/array.h>
#include <mruby/string.h>
#include <mruby/class.h>

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

void
js_bridge_define(mrb_state *mrb, struct RClass *js) {
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
}
