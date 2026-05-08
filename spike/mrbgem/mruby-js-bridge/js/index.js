// JS host adapter for the mruby-js-bridge mrbgem.
//
// Provides the JSBridge core via a single factory:
//
//   import { createVM, Directory, File } from "mruby-js-bridge";
//
//   const vm = await createVM({
//     wasm: "/path/to/mruby.wasm",
//     env: { LOCALE: "ja" },
//     fs: new Directory({ "data": new Directory({ "poem.vtt": new File(bytes) }) }),
//   });
//
//   vm.eval('puts ENV["LOCALE"]');
//   vm.fs.set("/late.txt", bytes);
//   vm.env["DEBUG"] = "1";
//
// Each createVM() call instantiates an independent mruby — separate
// handle table, separate WASI state. Multiple VMs can coexist in one
// process (useful for tests, sandboxing, hot reload).
//
// Internal layout:
//   - createHandleTable():        per-VM handle table (alloc/get/release/count)
//   - createErrorSlot():          per-VM JS exception capture
//   - inspectValue(v):            pure debug-string formatter
//   - createJsBridgeImports({…}): builds the 25 js_bridge.* methods
//   - createVM(options):          orchestrator — creates state,
//                                  builds imports, instantiates wasm,
//                                  runs _start, returns VM handle.

import { createWasiPreview1, createFsFacade, Directory, File } from "./wasi-preview1.js";
import { createMemoryHelpers, encoder } from "./_memory.js";
import { debug } from "./debug.js";

export { Directory, File, createFsFacade, debug };

// `env` import object for instantiateStreaming. Empty in current builds:
// the gem's mruby.wasm uses hal-wasi-io (mrbgem/hal-wasi-io/) for the
// IO HAL backend, and mruby-wasi-stubs (mrbgem/mruby-wasi-stubs/) for
// the few POSIX symbols mruby-io's io.c references directly (dup,
// waitpid). Both are linked into the wasm itself, leaving the `env`
// import module with nothing to satisfy.
const envImports = {};

// --- Pure helpers ---------------------------------------------------------

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
  if (v && typeof v.nodeType === "number" && typeof v.nodeName === "string") {
    return `#<JS ${v.nodeName.toLowerCase()}${v.id ? ` id=${JSON.stringify(v.id)}` : ""}>`;
  }
  try { return JSON.stringify(v); }
  catch (_err) { return `#<JS ${Object.prototype.toString.call(v)}>`; }
}

// --- Per-VM state factories -----------------------------------------------

/** Per-VM handle table. Index 0 is reserved as a "null" sentinel.
 *  Allocations recycle from a free list to keep handle numbers small. */
function createHandleTable() {
  const handles = [null];
  const free = [];
  return {
    alloc(value) {
      if (free.length > 0) {
        const h = free.pop();
        handles[h] = value;
        return h;
      }
      handles.push(value);
      return handles.length - 1;
    },
    get(h) { return handles[h]; },
    release(h) {
      if (h === 0) return;
      if (handles[h] === null) return;
      handles[h] = null;
      free.push(h);
    },
    count() { return handles.length - 1 - free.length; },
    isNull(h) { return h === 0 || handles[h] == null; },
  };
}

/** Per-VM "latest JS exception" slot. The C side calls js_take_error()
 *  right after each potentially-throwing op; if a non-null Error is
 *  pending, it becomes a JSBridge::Error on the Ruby side. Non-Error
 *  throws (`throw "string"`, `throw 42`, ...) are wrapped so callers
 *  always get an object with `.message`. */
function createErrorSlot() {
  let pending = null;
  return {
    capture(err) { pending = err; },
    take() {
      if (pending == null) return null;
      let err = pending;
      pending = null;
      if (!(err instanceof Error)) err = new Error(String(err));
      return err;
    },
  };
}

/** Build the 25 `js_bridge.*` import methods, closing over the supplied
 *  per-VM state. Splitting this out from createVM means the imports can
 *  be unit-tested or rebuilt independently of the wasm fetch/instantiate
 *  cycle. */
function createJsBridgeImports({ handles, errorSlot, getInstance }) {
  const { readUtf8, writeUtf8, readHandleArray } = createMemoryHelpers(getInstance);
  return {
    // Evaluate JS source and return a handle to the resulting value.
    // NOTE: uses `Function` constructor for simplicity; not a sandbox.
    js_eval(ptr, len) {
      const src = readUtf8(ptr, len);
      let result;
      try { result = new Function(`return (${src});`)(); }
      catch (err) { errorSlot.capture(err); return 0; }
      return handles.alloc(result);
    },
    js_global() { return handles.alloc(globalThis); },
    js_release(h) {
      if (debug.trace && h !== 0 && handles.get(h) !== null) {
        console.log(`[trace] js_release h=${h} (was ${typeof handles.get(h)})`);
      }
      handles.release(h);
    },
    js_get(h, keyPtr, keyLen) {
      const key = readUtf8(keyPtr, keyLen);
      const obj = handles.get(h);
      if (obj == null) {
        errorSlot.capture(new TypeError(`cannot read property '${key}' of ${obj}`));
        return 0;
      }
      try { return handles.alloc(obj[key]); }
      catch (err) { errorSlot.capture(err); return 0; }
    },
    js_set(h, keyPtr, keyLen, valueHandle) {
      const key = readUtf8(keyPtr, keyLen);
      const obj = handles.get(h);
      if (obj == null) {
        errorSlot.capture(new TypeError(`cannot set property '${key}' of ${obj}`));
        return;
      }
      try { obj[key] = handles.get(valueHandle); }
      catch (err) { errorSlot.capture(err); }
    },
    js_call(h, methodPtr, methodLen, argsPtr, argCount) {
      const method = readUtf8(methodPtr, methodLen);
      const obj = handles.get(h);
      if (obj == null) {
        errorSlot.capture(new TypeError(`cannot call '${method}' on ${obj}`));
        return 0;
      }
      const argHandles = readHandleArray(argsPtr, argCount);
      const args = argHandles.map((a) => handles.get(a));
      try { return handles.alloc(obj[method].apply(obj, args)); }
      catch (err) { errorSlot.capture(err); return 0; }
    },
    js_new(h, argsPtr, argCount) {
      const ctor = handles.get(h);
      if (typeof ctor !== "function") {
        errorSlot.capture(new TypeError(`handle ${h} is not a constructor`));
        return 0;
      }
      const argHandles = readHandleArray(argsPtr, argCount);
      const args = argHandles.map((a) => handles.get(a));
      try { return handles.alloc(new ctor(...args)); }
      catch (err) { errorSlot.capture(err); return 0; }
    },
    js_handle_count() { return handles.count(); },
    js_take_error() {
      const err = errorSlot.take();
      return err == null ? 0 : handles.alloc(err);
    },
    js_to_string_len(h) {
      const v = handles.get(h);
      return v == null ? 0 : encoder.encode(String(v)).length;
    },
    js_to_string_copy(h, ptr, bufLen) {
      const v = handles.get(h);
      if (v == null) return;
      writeUtf8(String(v), ptr, bufLen);
    },
    js_from_string(ptr, len) { return handles.alloc(readUtf8(ptr, len)); },
    js_to_int(h) {
      const v = handles.get(h);
      return v == null ? 0 : (v | 0);
    },
    js_from_int(v) { return handles.alloc(v); },
    js_to_float(h) {
      const v = handles.get(h);
      return v == null ? 0 : Number(v);
    },
    js_from_float(v) { return handles.alloc(v); },
    js_is_null(h) { return handles.isNull(h) ? 1 : 0; },
    js_strict_equal(a, b) { return handles.get(a) === handles.get(b) ? 1 : 0; },
    js_typeof_len(h) { return encoder.encode(typeof handles.get(h)).length; },
    js_typeof_copy(h, ptr, bufLen) { writeUtf8(typeof handles.get(h), ptr, bufLen); },
    js_inspect_len(h) { return encoder.encode(inspectValue(handles.get(h))).length; },
    js_inspect_copy(h, ptr, bufLen) { writeUtf8(inspectValue(handles.get(h)), ptr, bufLen); },
    js_instanceof(instanceH, ctorH) {
      const ctor = handles.get(ctorH);
      if (typeof ctor !== "function") return 0;
      try { return handles.get(instanceH) instanceof ctor ? 1 : 0; }
      catch (_err) { return 0; }
    },
    js_make_callback(callbackId) {
      const wrapper = (...args) => {
        if (debug.trace) console.log(`[trace] wrapper id=${callbackId} fired with`, args);
        const argsHandle = handles.alloc(args);
        try { getInstance().exports.js_bridge_invoke_proc(callbackId, argsHandle); }
        finally { handles.release(argsHandle); }
      };
      return handles.alloc(wrapper);
    },
  };
}

// --- Public factory -------------------------------------------------------

/**
 * Instantiate a fresh mruby VM and return a handle for driving it.
 *
 * @param {object} options
 * @param {string} options.wasm                  URL to mruby.wasm
 * @param {Record<string, string>} [options.env] initial ENV
 * @param {string[]} [options.args]              initial ARGV (defaults to ["mruby-js-bridge"])
 * @param {string|Uint8Array} [options.stdin]    initial stdin payload
 * @param {Directory} [options.fs]               initial root Directory for the VFS
 * @param {object} [options.wasi]                replacement `wasi_snapshot_preview1` import object;
 *                                                defaults to a fresh in-memory WASI preview1 impl
 * @param {(instance: WebAssembly.Instance) => void} [options.onStart]
 *                                                called once after instantiation; defaults to
 *                                                calling `instance.exports._start()`
 *
 * @returns {Promise<{
 *   instance: WebAssembly.Instance,
 *   eval: (source: string) => number,           // 0 on success, 1 on parse/runtime error
 *   alloc: (value: any) => number,               // power-user handle table
 *   get: (handle: number) => any,
 *   release: (handle: number) => void,
 *   handleCount: () => number,
 *   fs?: object,                                 // present iff bundled WASI is in use
 *   env?: Record<string, string>,                // present iff bundled WASI is in use
 *   args?: string[],                             // present iff bundled WASI is in use
 *   stdin?: { bytes: Uint8Array, pushText: (s: string) => void },  // present iff bundled WASI is in use
 * }>}
 *
 * Note: when `options.wasi` is provided, the returned VM does NOT include
 * `fs` / `env` / `args` / `stdin` — those keys describe the bundled
 * WASI preview1's state, and the caller's WASI replacement owns its own
 * state instead. This keeps the typed surface of the returned object
 * consistent with which WASI is actually backing it.
 *
 * Swap WASI for `@bjorn3/browser_wasi_shim`:
 *
 *     import { WASI } from "@bjorn3/browser_wasi_shim";
 *     const wasi = new WASI([], [], preopens);
 *     const vm = await createVM({
 *       wasm: "/path/to/mruby.wasm",
 *       wasi: wasi.wasiImport,
 *       onStart: (instance) => wasi.start(instance),
 *     });
 *
 * The `js_bridge.*` imports (the JSBridge layer itself) are always
 * provided by this adapter regardless of which WASI is used.
 */
export async function createVM(options = {}) {
  const { wasm, onStart } = options;
  if (!wasm) throw new Error("createVM: options.wasm (URL to mruby.wasm) is required");

  const handles = createHandleTable();
  const errorSlot = createErrorSlot();
  let instance = null;
  const getInstance = () => instance;

  const jsBridgeImports = createJsBridgeImports({ handles, errorSlot, getInstance });

  const customWasi = options.wasi;
  const wasiImpl = customWasi ? null : createWasiPreview1({
    env: options.env,
    args: options.args,
    stdin: options.stdin,
    fs: options.fs,
  });
  const wasiImports = customWasi ?? wasiImpl.imports;

  const response = await fetch(wasm);
  if (!response.ok) {
    throw new Error(`createVM: failed to fetch ${wasm}: ${response.status}`);
  }
  const result = await WebAssembly.instantiateStreaming(response, {
    env: envImports,
    js_bridge: jsBridgeImports,
    wasi_snapshot_preview1: wasiImports,
  });
  instance = result.instance;
  if (wasiImpl) wasiImpl.bindInstance(instance);

  if (onStart) {
    onStart(instance);
  } else if (typeof instance.exports._start === "function") {
    try { instance.exports._start(); }
    catch (err) {
      if (err.message && !err.message.includes("exit")) throw err;
    }
  }

  function evalRuby(source) {
    const handle = handles.alloc(source);
    try { return instance.exports.js_bridge_eval_handle(handle); }
    finally { handles.release(handle); }
  }

  // Core VM surface plus, when we own the WASI side, the bundled VFS
  // state (fs / env / args / stdin). Keys are omitted entirely when
  // the caller passed their own `wasi` — that object controls fs/env/
  // args/stdin, and `undefined` placeholders are harder to typecheck
  // and easier to misread than absent properties.
  return {
    instance,
    eval: evalRuby,
    alloc: handles.alloc,
    get: handles.get,
    release: handles.release,
    handleCount: () => handles.count(),
    ...(wasiImpl && {
      fs: wasiImpl.fs,
      env: wasiImpl.env,
      args: wasiImpl.args,
      stdin: wasiImpl.stdin,
    }),
  };
}
