/*
 * JS::Object — BasicObject subclass with MRB_TT_DATA. Each instance owns
 * a JS handle that the GC free callback releases. Also houses JS::Error
 * and the helpers that turn a pending JS adapter exception into a Ruby
 * `JS::Error` raise.
 */
#include "imports.h"
#include <mruby/string.h>
#include <mruby/class.h>
#include <mruby/variable.h>

/* Globals owned here (declarations live in imports.h) */
mrb_value g_object_class_obj;
mrb_value g_error_class_obj;

/* ---------- JS::Object data type ---------- */

typedef struct {
  int handle;
} js_object_t;

static void
js_object_free(mrb_state *mrb, void *ptr) {
  if (ptr) {
    js_object_t *v = (js_object_t *)ptr;
    if (v->handle != 0) {
      js_release(v->handle);
    }
    mrb_free(mrb, v);
  }
}

const struct mrb_data_type js_object_type = {
  "JS::Object",
  js_object_free,
};

static mrb_value
mrb_js_object_init(mrb_state *mrb, mrb_value self) {
  mrb_int handle;
  mrb_get_args(mrb, "i", &handle);
  js_object_t *v = (js_object_t *)mrb_malloc(mrb, sizeof(*v));
  v->handle = (int)handle;
  mrb_data_init(self, v, &js_object_type);
  return self;
}

static mrb_value
mrb_js_object_handle(mrb_state *mrb, mrb_value self) {
  js_object_t *v = (js_object_t *)mrb_data_get_ptr(mrb, self, &js_object_type);
  return mrb_fixnum_value(v->handle);
}

/* Helper: wrap an int handle as a JS::Object object. */
mrb_value
wrap_handle(mrb_state *mrb, int handle) {
  mrb_value handle_val = mrb_fixnum_value(handle);
  return mrb_obj_new(mrb, mrb_class_ptr(g_object_class_obj), 1, &handle_val);
}

/* ---------- JS error → Ruby JS::Error raise ---------- */

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
 * js_new / js_eval, raise JS::Error with the JS Error's `.message`
 * as the Ruby exception message AND the original JS Error attached as
 * @exception_object (so users can read .name / .stack / .cause / etc. from
 * Ruby). Called at the end of each primitive that can dispatch to JS. */
void
raise_if_js_error(mrb_state *mrb) {
  int err_h = js_take_error();
  if (err_h == 0) return;

  mrb_value msg = extract_error_message(mrb, err_h);
  /* wrap_handle takes ownership: JS::Object's GC free callback will release. */
  mrb_value js_err_obj = wrap_handle(mrb, err_h);

  /* Construct JS::Error.new(msg) and attach @exception_object. */
  mrb_value exc = mrb_funcall(mrb, g_error_class_obj, "new", 1, msg);
  mrb_iv_set(mrb, exc, mrb_intern_lit(mrb, "@exception_object"), js_err_obj);
  mrb_exc_raise(mrb, exc);
}

/* ---------- Class registration ---------- */

void
js_object_define(mrb_state *mrb, struct RClass *js) {
  /* JS::Error < StandardError — raised when a JS call throws. */
  struct RClass *err_cls = mrb_define_class_under(
    mrb, js, "Error", mrb_class_get(mrb, "StandardError"));
  g_error_class_obj = mrb_obj_value(err_cls);
  mrb_gc_register(mrb, g_error_class_obj);

  /* JS::Object — BasicObject subclass so method_missing forwards
     almost everything to JS without colliding with Ruby's Object
     methods (then, tap, itself, ==, inspect, ...). Matches ruby.wasm's
     JS::Object design exactly. */
  struct RClass *basic_object = mrb_class_get(mrb, "BasicObject");
  struct RClass *object_cls = mrb_define_class_under(mrb, js, "Object", basic_object);
  MRB_SET_INSTANCE_TT(object_cls, MRB_TT_DATA);
  mrb_define_method(mrb, object_cls, "initialize", mrb_js_object_init, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, object_cls, "handle", mrb_js_object_handle, MRB_ARGS_NONE());
  g_object_class_obj = mrb_obj_value(object_cls);
  mrb_gc_register(mrb, g_object_class_obj);
}
