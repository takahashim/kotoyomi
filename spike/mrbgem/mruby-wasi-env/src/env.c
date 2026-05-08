/*
 * mruby-wasi-env: ENV constant backed by wasi-libc.
 *
 * mruby core ships no ENV class. wasi-libc exposes the standard POSIX
 * triad (`extern char **environ`, getenv, setenv, unsetenv) populated
 * from the WASI imports `environ_get` / `environ_sizes_get` at startup
 * — mruby-wasm-js's wasi-preview1.js implements those imports against
 * a JS-side `env` object. Any other preview1-compatible host adapter
 * works too.
 *
 * Surface (subset of CRuby's ENV that maps cleanly to wasi-libc):
 *   ENV[key]                -> String | nil
 *   ENV[key] = value        -> setenv(key, value); nil unsets
 *   ENV.store(key, value)   -> alias of []=
 *   ENV.delete(key)         -> previous value or nil
 *   ENV.key?(key)           -> bool  (aliases: include?, has_key?, member?)
 *   ENV.keys / .values      -> Array<String>
 *   ENV.to_h / .to_hash     -> Hash<String, String>
 *   ENV.size / .length      -> Integer
 *   ENV.each { |k, v| ... } -> ENV
 *   ENV.each_pair, .each_key, .each_value (via mrblib + Enumerable)
 *
 * Out of scope: ENV.update / .merge! / .clear / .replace / regex
 * filtering — addable on top of the primitives above when a caller
 * needs them.
 *
 * NB: setenv/unsetenv mutate wasi-libc's process-local table only. The
 * changes don't propagate back to the JS host's `env` object, and
 * they're discarded at the next boot().
 */

#include <mruby.h>
#include <mruby/array.h>
#include <mruby/hash.h>
#include <mruby/string.h>
#include <stdlib.h>
#include <string.h>

extern char **environ;

static mrb_value
mrb_env_get(mrb_state *mrb, mrb_value self) {
  const char *key;
  mrb_get_args(mrb, "z", &key);
  const char *val = getenv(key);
  return val ? mrb_str_new_cstr(mrb, val) : mrb_nil_value();
}

static mrb_value
mrb_env_set(mrb_state *mrb, mrb_value self) {
  const char *key;
  mrb_value value;
  mrb_get_args(mrb, "zo", &key, &value);
  if (mrb_nil_p(value)) {
    unsetenv(key);
    return mrb_nil_value();
  }
  const char *str = mrb_string_cstr(mrb, value);
  setenv(key, str, 1);
  return value;
}

static mrb_value
mrb_env_delete(mrb_state *mrb, mrb_value self) {
  const char *key;
  mrb_get_args(mrb, "z", &key);
  const char *val = getenv(key);
  mrb_value result = val ? mrb_str_new_cstr(mrb, val) : mrb_nil_value();
  unsetenv(key);
  return result;
}

static mrb_value
mrb_env_key_p(mrb_state *mrb, mrb_value self) {
  const char *key;
  mrb_get_args(mrb, "z", &key);
  return getenv(key) ? mrb_true_value() : mrb_false_value();
}

static mrb_value
mrb_env_keys(mrb_state *mrb, mrb_value self) {
  mrb_value ary = mrb_ary_new(mrb);
  for (char **p = environ; *p; p++) {
    char *eq = strchr(*p, '=');
    if (!eq) continue;
    mrb_ary_push(mrb, ary, mrb_str_new(mrb, *p, eq - *p));
  }
  return ary;
}

static mrb_value
mrb_env_values(mrb_state *mrb, mrb_value self) {
  mrb_value ary = mrb_ary_new(mrb);
  for (char **p = environ; *p; p++) {
    char *eq = strchr(*p, '=');
    if (!eq) continue;
    mrb_ary_push(mrb, ary, mrb_str_new_cstr(mrb, eq + 1));
  }
  return ary;
}

static mrb_value
mrb_env_to_h(mrb_state *mrb, mrb_value self) {
  mrb_value hash = mrb_hash_new(mrb);
  for (char **p = environ; *p; p++) {
    char *eq = strchr(*p, '=');
    if (!eq) continue;
    mrb_value k = mrb_str_new(mrb, *p, eq - *p);
    mrb_value v = mrb_str_new_cstr(mrb, eq + 1);
    mrb_hash_set(mrb, hash, k, v);
  }
  return hash;
}

static mrb_value
mrb_env_size(mrb_state *mrb, mrb_value self) {
  mrb_int n = 0;
  for (char **p = environ; *p; p++) n++;
  return mrb_fixnum_value(n);
}

static mrb_value
mrb_env_each(mrb_state *mrb, mrb_value self) {
  mrb_value block;
  mrb_get_args(mrb, "&", &block);
  if (mrb_nil_p(block)) return self; // no Enumerator in core; just no-op
  for (char **p = environ; *p; p++) {
    char *eq = strchr(*p, '=');
    if (!eq) continue;
    mrb_value k = mrb_str_new(mrb, *p, eq - *p);
    mrb_value v = mrb_str_new_cstr(mrb, eq + 1);
    mrb_value pair = mrb_ary_new_capa(mrb, 2);
    mrb_ary_push(mrb, pair, k);
    mrb_ary_push(mrb, pair, v);
    mrb_yield(mrb, block, pair);
  }
  return self;
}

void
mrb_mruby_wasi_env_gem_init(mrb_state *mrb) {
  // ENV is a singleton-like Module — module functions provide the
  // hash-like surface, and `ENV` is the constant the user touches.
  struct RClass *env = mrb_define_module(mrb, "ENV");
  mrb_define_module_function(mrb, env, "[]",       mrb_env_get,    MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, env, "[]=",      mrb_env_set,    MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, env, "store",    mrb_env_set,    MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, env, "delete",   mrb_env_delete, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, env, "key?",     mrb_env_key_p,  MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, env, "include?", mrb_env_key_p,  MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, env, "has_key?", mrb_env_key_p,  MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, env, "member?",  mrb_env_key_p,  MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, env, "keys",     mrb_env_keys,   MRB_ARGS_NONE());
  mrb_define_module_function(mrb, env, "values",   mrb_env_values, MRB_ARGS_NONE());
  mrb_define_module_function(mrb, env, "to_h",     mrb_env_to_h,   MRB_ARGS_NONE());
  mrb_define_module_function(mrb, env, "to_hash",  mrb_env_to_h,   MRB_ARGS_NONE());
  mrb_define_module_function(mrb, env, "size",     mrb_env_size,   MRB_ARGS_NONE());
  mrb_define_module_function(mrb, env, "length",   mrb_env_size,   MRB_ARGS_NONE());
  mrb_define_module_function(mrb, env, "each",     mrb_env_each,   MRB_ARGS_BLOCK());
}

void
mrb_mruby_wasi_env_gem_final(mrb_state *mrb) {
}
