// JS host adapter for the mruby-js-bridge mrbgem.
//
// Provides the JSBridge core:
//   - Handle table for JS values exposed to Ruby
//   - Implementation of all js_bridge.* imports the mrbgem declares
//   - boot() / evalRuby() to instantiate the WASM and run mruby code
//
// The default WASI preview1 implementation (in-memory fs / clock /
// random / env / args / stdin) lives in `./wasi-preview1.js` and is
// re-exported below. It can be swapped per-boot via
// `boot(url, { wasi })` — see boot()'s JSDoc.

import {
  bindInstance as bindWasiInstance,
  wasiImports,
} from "./wasi-preview1.js";
import { debug } from "./debug.js";
export { wasiImports, debug };
export { env, args, stdin, fs } from "./wasi-preview1.js";

// --- Handle table -----------------------------------------------------------
// index 0 is reserved as a "null" sentinel. Allocations recycle from a free
// list to keep handle numbers small.
const handles = [null];
const free = [];

export function alloc(value) {
  if (free.length > 0) {
    const h = free.pop();
    handles[h] = value;
    return h;
  }
  handles.push(value);
  return handles.length - 1;
}

export function get(h) {
  return handles[h];
}

export function release(h) {
  if (h === 0) return; // never release the null sentinel
  if (handles[h] === null) return; // idempotent: already released
  handles[h] = null;
  free.push(h);
}

// --- WASM imports for mruby-js-bridge -------------------------------------------
// `instance` is set after WebAssembly.instantiate so the imports can read
// the linear memory.
let instance = null;
const decoder = new TextDecoder("utf-8");
const encoder = new TextEncoder();

// Latest JS exception caught by a primitive. The C side calls
// js_take_error() right after each potentially-throwing op; if a handle
// is returned, mruby raises JSBridge::Error with the message string.
let pendingError = null;

function captureError(err) {
  pendingError = err;
}

function readUtf8(ptr, len) {
  const memory = instance.exports.memory;
  const bytes = new Uint8Array(memory.buffer, ptr, len);
  return decoder.decode(bytes);
}

function writeUtf8(s, ptr, maxLen) {
  const memory = instance.exports.memory;
  const view = new Uint8Array(memory.buffer, ptr, maxLen);
  const encoded = encoder.encode(s);
  const n = Math.min(encoded.length, maxLen);
  view.set(encoded.subarray(0, n));
  return n;
}

// Best-effort debug string for a JS value. JSON for plain objects so
// `p value` shows structure; tag DOM nodes / functions specially since
// JSON.stringify drops them.
function inspectValue(v) {
  if (v === null) return "null";
  if (v === undefined) return "undefined";
  const t = typeof v;
  if (t === "string") return JSON.stringify(v);
  if (t === "number" || t === "boolean") return String(v);
  if (t === "function") return `#<JS function ${v.name || "(anonymous)"}>`;
  if (t === "symbol") return v.toString();
  // DOM-ish detection without referencing window.
  if (v && typeof v.nodeType === "number" && typeof v.nodeName === "string") {
    return `#<JS ${v.nodeName.toLowerCase()}${v.id ? ` id=${JSON.stringify(v.id)}` : ""}>`;
  }
  try {
    return JSON.stringify(v);
  } catch (_err) {
    return `#<JS ${Object.prototype.toString.call(v)}>`;
  }
}

function readHandleArray(ptr, count) {
  if (count <= 0) return [];
  const view = new DataView(instance.exports.memory.buffer);
  const out = new Array(count);
  for (let i = 0; i < count; i++) out[i] = view.getInt32(ptr + i * 4, true);
  return out;
}

const jsBridgeImports = {
  // Evaluate JS source and return a handle to the resulting value.
  // NOTE: uses `Function` constructor for simplicity; not a sandbox.
  js_eval(ptr, len) {
    const src = readUtf8(ptr, len);
    let result;
    try {
      result = new Function(`return (${src});`)();
    } catch (err) {
      captureError(err);
      return 0;
    }
    return alloc(result);
  },

  // Returns handle to globalThis.
  js_global() {
    return alloc(globalThis);
  },

  js_release(h) {
    if (debug.trace && h !== 0 && handles[h] !== null) {
      console.log(`[trace] js_release h=${h} (was ${typeof handles[h]})`);
    }
    release(h);
  },

  // Get a property: handle[key] → handle
  js_get(h, keyPtr, keyLen) {
    const key = readUtf8(keyPtr, keyLen);
    const obj = get(h);
    if (obj == null) {
      captureError(new TypeError(`cannot read property '${key}' of ${obj}`));
      return 0;
    }
    try {
      return alloc(obj[key]);
    } catch (err) {
      captureError(err);
      return 0;
    }
  },

  // Set a property: handle[key] = valueHandle's value
  js_set(h, keyPtr, keyLen, valueHandle) {
    const key = readUtf8(keyPtr, keyLen);
    const obj = get(h);
    if (obj == null) {
      captureError(new TypeError(`cannot set property '${key}' of ${obj}`));
      return;
    }
    try {
      obj[key] = get(valueHandle);
    } catch (err) {
      captureError(err);
    }
  },

  // Call a method: handle.method(...args) → handle
  // args: pointer to array of i32 handles, count: number of args
  js_call(h, methodPtr, methodLen, argsPtr, argCount) {
    const method = readUtf8(methodPtr, methodLen);
    const obj = get(h);
    if (obj == null) {
      captureError(new TypeError(`cannot call '${method}' on ${obj}`));
      return 0;
    }
    const argHandles = readHandleArray(argsPtr, argCount);
    const args = argHandles.map(get);
    try {
      return alloc(obj[method].apply(obj, args));
    } catch (err) {
      captureError(err);
      return 0;
    }
  },

  // Construct a new instance: new handle(...args). Returns handle to the
  // resulting object. Used for `Date.new(...)`, `Map.new`, etc.
  js_new(h, argsPtr, argCount) {
    const ctor = get(h);
    if (typeof ctor !== "function") {
      captureError(new TypeError(`handle ${h} is not a constructor`));
      return 0;
    }
    const argHandles = readHandleArray(argsPtr, argCount);
    const args = argHandles.map(get);
    try {
      return alloc(new ctor(...args));
    } catch (err) {
      captureError(err);
      return 0;
    }
  },

  // Diagnostic: # of currently-allocated JS handles (active = total
  // pushed minus released to the free list). Excludes the null sentinel
  // at index 0. Used by JSBridge.stats.
  js_handle_count() {
    return handles.length - 1 - free.length;
  },

  // Take and clear the most recent JS error. Returns 0 if no error
  // pending; otherwise returns a handle to the Error VALUE itself
  // (consumed — second call returns 0 unless a new error fires).
  // Ruby side wraps it as a JSBridge::Value so callers can inspect
  // `.name`, `.stack`, `.cause`, etc. via `JSBridge::Error#js_value`.
  // Non-Error throws (`throw "string"`, `throw 42`, ...) are wrapped in
  // an Error so the caller always gets an object with a `.message`.
  js_take_error() {
    if (pendingError == null) return 0;
    let err = pendingError;
    pendingError = null;
    if (!(err instanceof Error)) {
      err = new Error(String(err));
    }
    return alloc(err);
  },

  // Get UTF-8 byte length of stringification (so caller can allocate buffer).
  js_to_string_len(h) {
    const v = get(h);
    return v == null ? 0 : encoder.encode(String(v)).length;
  },

  // Copy UTF-8 bytes of stringification into memory at ptr (up to bufLen).
  js_to_string_copy(h, ptr, bufLen) {
    const v = get(h);
    if (v == null) return;
    writeUtf8(String(v), ptr, bufLen);
  },

  // Allocate a handle for a JS string built from UTF-8 bytes.
  js_from_string(ptr, len) {
    return alloc(readUtf8(ptr, len));
  },

  // Read i32-ish JS number as int.
  js_to_int(h) {
    const v = get(h);
    return v == null ? 0 : (v | 0);
  },

  // Allocate a handle for a JS number.
  js_from_int(v) {
    return alloc(v);
  },

  // Read a JS number as a double (for currentTime, cue start/end, etc.).
  js_to_float(h) {
    const v = get(h);
    return v == null ? 0 : Number(v);
  },

  // Allocate a handle for a JS number from a Ruby Float (passed as a double).
  js_from_float(v) {
    return alloc(v);
  },

  // Returns 1 if the wrapped JS value is null or undefined.
  // Used by Value#nil? on the Ruby side.
  js_is_null(h) {
    return (h === 0 || handles[h] == null) ? 1 : 0;
  },

  // JS strict equality (===). Used by Value#==.
  js_strict_equal(a, b) {
    return get(a) === get(b) ? 1 : 0;
  },

  // JS typeof — returns string ("number", "string", "object", etc.).
  // Pair of len/copy lets the C side allocate the right-size buffer.
  js_typeof_len(h) {
    return encoder.encode(typeof get(h)).length;
  },
  js_typeof_copy(h, ptr, bufLen) {
    writeUtf8(typeof get(h), ptr, bufLen);
  },

  // Debug-friendly stringification. JSON for plain objects/arrays,
  // String() otherwise. Used by Value#inspect.
  js_inspect_len(h) {
    return encoder.encode(inspectValue(get(h))).length;
  },
  js_inspect_copy(h, ptr, bufLen) {
    writeUtf8(inspectValue(get(h)), ptr, bufLen);
  },

  // JS instanceof — `instance instanceof ctor`. Used by Value#instanceof?.
  js_instanceof(instanceH, ctorH) {
    const ctor = get(ctorH);
    if (typeof ctor !== "function") return 0;
    try {
      return get(instanceH) instanceof ctor ? 1 : 0;
    } catch (_err) {
      return 0;
    }
  },

  // Create a JS function that, when called, dispatches into mruby with
  // the given callback id. Returns a handle to the wrapper function.
  js_make_callback(callbackId) {
    const wrapper = (...args) => {
      if (debug.trace) console.log(`[trace] wrapper id=${callbackId} fired with`, args);
      const argsHandle = alloc(args);
      try {
        instance.exports.js_bridge_invoke_proc(callbackId, argsHandle);
      } finally {
        release(argsHandle);
      }
    };
    return alloc(wrapper);
  },
};

// --- env: SJLJ helpers (resolved by libsetjmp.a, kept empty as fallback) ----
const envImports = {};

// Stub out POSIX functions that mruby-io / hal-posix-io reference but
// wasi-libc doesn't ship. With mruby 4.0.0, the HAL was extracted to
// `hal-posix-io` (which gets linked into the wasm), and that gem's
// io_hal.c calls real POSIX APIs — many of which wasi-libc lacks. The
// kotoyomi spike never exercises File.open / Process.spawn / IO.popen
// etc. so all of these can safely be no-ops.
const ioStubNames = [
  // process control — none of these have a meaningful WASI counterpart
  "dup", "dup2", "waitpid", "pipe", "fork", "execl",
  // file mode / permission
  "umask",
  // file locking (POSIX flock; WASI uses path_lock in capabilities-style)
  "flock",
  // passwd database (hal-posix-io's gethome lookup)
  "getpwnam",
];
for (const name of ioStubNames) {
  envImports[name] = (..._args) => -1;
}

// Load a Ruby source string into the live mruby VM.
// Returns 0 on success, 1 on parse/runtime error (printed to stderr by mruby).
export function evalRuby(source) {
  if (!instance) throw new Error("evalRuby called before boot()");
  const handle = alloc(source);
  try {
    return instance.exports.js_bridge_eval_handle(handle);
  } finally {
    release(handle);
  }
}

// --- Boot -------------------------------------------------------------------
/**
 * Instantiate the wasm and run `_start`.
 *
 * @param {string} wasmUrl  URL to mruby.wasm.
 * @param {object} [options]
 *
 * @param {object} [options.wasi]
 *   Custom `wasi_snapshot_preview1` import object. Defaults to the
 *   bundled `wasiImports` (in-memory FS via the exported `fs` Map,
 *   env/args/stdin from the exported objects above, real clock/random).
 *
 *   To swap in a more capable shim such as `@bjorn3/browser_wasi_shim`
 *   (tree VFS, fd_readdir, OPFS bindings, multiple preopens, etc.):
 *
 *     import { boot } from "mruby-js-bridge";
 *     import { WASI } from "@bjorn3/browser_wasi_shim";
 *
 *     const wasi = new WASI([], [], [...preopens]);
 *     await boot(url, {
 *       wasi: wasi.wasiImport,
 *       onStart: (instance) => wasi.start(instance),
 *     });
 *
 *   The `js_bridge.*` imports (the JSBridge layer itself) are always
 *   provided by this adapter regardless of which WASI is used.
 *
 * @param {(instance: WebAssembly.Instance) => void} [options.onStart]
 *   Called once immediately after `WebAssembly.instantiateStreaming`.
 *   Default behaviour: call `instance.exports._start()` (the WASI
 *   command-module entry).
 *
 *   Override this when your custom WASI needs to bind the instance
 *   before `_start` runs (browser_wasi_shim does:
 *   `wasi.start(instance)` which sets `wasi.inst = instance` and *then*
 *   invokes `_start`). The bundled `wasiImports` reads the instance
 *   lazily at every call so the default works without a custom hook.
 */
export async function boot(wasmUrl, options = {}) {
  const wasi = options.wasi ?? wasiImports;
  const response = await fetch(wasmUrl);
  if (!response.ok) {
    throw new Error(`Failed to fetch ${wasmUrl}: ${response.status}`);
  }
  const result = await WebAssembly.instantiateStreaming(response, {
    env: envImports,
    js_bridge: jsBridgeImports,
    wasi_snapshot_preview1: wasi,
  });
  instance = result.instance;
  // Bind the bundled WASI module's instance reference too. Harmless
  // even when the caller passed `options.wasi` — the bundled imports
  // simply won't be invoked in that case.
  bindWasiInstance(instance);

  if (options.onStart) {
    options.onStart(instance);
  } else if (typeof instance.exports._start === "function") {
    try {
      instance.exports._start();
    } catch (err) {
      if (err.message && !err.message.includes("exit")) throw err;
    }
  }
  return instance;
}
