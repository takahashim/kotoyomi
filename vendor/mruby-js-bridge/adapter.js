// JS host adapter for the mruby-js-bridge mrbgem.
//
// Provides the JSBridge core via a single factory:
//
//   import { createVM, Directory, File } from "<gem>/js/adapter.js";
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
// The default WASI preview1 implementation lives in `./wasi-preview1.js`.
// To swap it out (e.g. `@bjorn3/browser_wasi_shim`), pass `options.wasi`.

import { createWasiPreview1, Directory, File } from "./wasi-preview1.js";
import { debug } from "./debug.js";

export { Directory, File, debug };

// POSIX function stubs that mruby-io / hal-posix-io reference but
// wasi-libc doesn't ship. With mruby 4.0.0 the HAL was extracted to
// `hal-posix-io`, and that gem's io_hal.c calls real POSIX APIs —
// many of which wasi-libc lacks. Stubs return -1 for everything; the
// kotoyomi spike never exercises Process.spawn / IO.popen / umask
// etc. so this is safe in practice.
//
// These imports are wasm-binary-shape-dependent (the linker decides
// which to require), not VM-state-dependent, so a single shared object
// is reused across every createVM() call.
const POSIX_STUB_NAMES = [
  "dup", "dup2", "waitpid", "pipe", "fork", "execl",
  "umask", "flock", "getpwnam",
];
const envImports = {};
for (const name of POSIX_STUB_NAMES) envImports[name] = (..._args) => -1;

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
 *   fs: object,                                  // Map-compatible facade
 *   env: Record<string, string>,
 *   args: string[],
 *   stdin: { bytes: Uint8Array, pushText: (s: string) => void },
 *   alloc: (value: any) => number,               // power-user handle table
 *   get: (handle: number) => any,
 *   release: (handle: number) => void,
 *   handleCount: () => number,
 * }>}
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

  // --- Per-VM state ------------------------------------------------------
  // Handle table for JS values exposed to Ruby. Index 0 is the null
  // sentinel; allocations recycle from a free list.
  const handles = [null];
  const free = [];
  function alloc(value) {
    if (free.length > 0) {
      const h = free.pop();
      handles[h] = value;
      return h;
    }
    handles.push(value);
    return handles.length - 1;
  }
  function get(h) { return handles[h]; }
  function release(h) {
    if (h === 0) return;
    if (handles[h] === null) return;
    handles[h] = null;
    free.push(h);
  }

  let instance = null;
  const decoder = new TextDecoder("utf-8");
  const encoder = new TextEncoder();
  let pendingError = null;
  function captureError(err) { pendingError = err; }

  // --- Memory helpers (close over `instance`) ----------------------------
  function readUtf8(ptr, len) {
    const memory = instance.exports.memory;
    return decoder.decode(new Uint8Array(memory.buffer, ptr, len));
  }
  function writeUtf8(s, ptr, maxLen) {
    const memory = instance.exports.memory;
    const view = new Uint8Array(memory.buffer, ptr, maxLen);
    const encoded = encoder.encode(s);
    const n = Math.min(encoded.length, maxLen);
    view.set(encoded.subarray(0, n));
    return n;
  }
  function readHandleArray(ptr, count) {
    if (count <= 0) return [];
    const view = new DataView(instance.exports.memory.buffer);
    const out = new Array(count);
    for (let i = 0; i < count; i++) out[i] = view.getInt32(ptr + i * 4, true);
    return out;
  }

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

  // --- js_bridge.* imports (close over per-VM handle table) ---------------
  const jsBridgeImports = {
    js_eval(ptr, len) {
      const src = readUtf8(ptr, len);
      let result;
      try { result = new Function(`return (${src});`)(); }
      catch (err) { captureError(err); return 0; }
      return alloc(result);
    },
    js_global() { return alloc(globalThis); },
    js_release(h) {
      if (debug.trace && h !== 0 && handles[h] !== null) {
        console.log(`[trace] js_release h=${h} (was ${typeof handles[h]})`);
      }
      release(h);
    },
    js_get(h, keyPtr, keyLen) {
      const key = readUtf8(keyPtr, keyLen);
      const obj = get(h);
      if (obj == null) {
        captureError(new TypeError(`cannot read property '${key}' of ${obj}`));
        return 0;
      }
      try { return alloc(obj[key]); }
      catch (err) { captureError(err); return 0; }
    },
    js_set(h, keyPtr, keyLen, valueHandle) {
      const key = readUtf8(keyPtr, keyLen);
      const obj = get(h);
      if (obj == null) {
        captureError(new TypeError(`cannot set property '${key}' of ${obj}`));
        return;
      }
      try { obj[key] = get(valueHandle); }
      catch (err) { captureError(err); }
    },
    js_call(h, methodPtr, methodLen, argsPtr, argCount) {
      const method = readUtf8(methodPtr, methodLen);
      const obj = get(h);
      if (obj == null) {
        captureError(new TypeError(`cannot call '${method}' on ${obj}`));
        return 0;
      }
      const argHandles = readHandleArray(argsPtr, argCount);
      const args = argHandles.map(get);
      try { return alloc(obj[method].apply(obj, args)); }
      catch (err) { captureError(err); return 0; }
    },
    js_new(h, argsPtr, argCount) {
      const ctor = get(h);
      if (typeof ctor !== "function") {
        captureError(new TypeError(`handle ${h} is not a constructor`));
        return 0;
      }
      const argHandles = readHandleArray(argsPtr, argCount);
      const args = argHandles.map(get);
      try { return alloc(new ctor(...args)); }
      catch (err) { captureError(err); return 0; }
    },
    js_handle_count() { return handles.length - 1 - free.length; },
    js_take_error() {
      if (pendingError == null) return 0;
      let err = pendingError;
      pendingError = null;
      if (!(err instanceof Error)) err = new Error(String(err));
      return alloc(err);
    },
    js_to_string_len(h) {
      const v = get(h);
      return v == null ? 0 : encoder.encode(String(v)).length;
    },
    js_to_string_copy(h, ptr, bufLen) {
      const v = get(h);
      if (v == null) return;
      writeUtf8(String(v), ptr, bufLen);
    },
    js_from_string(ptr, len) { return alloc(readUtf8(ptr, len)); },
    js_to_int(h) {
      const v = get(h);
      return v == null ? 0 : (v | 0);
    },
    js_from_int(v) { return alloc(v); },
    js_to_float(h) {
      const v = get(h);
      return v == null ? 0 : Number(v);
    },
    js_from_float(v) { return alloc(v); },
    js_is_null(h) { return (h === 0 || handles[h] == null) ? 1 : 0; },
    js_strict_equal(a, b) { return get(a) === get(b) ? 1 : 0; },
    js_typeof_len(h) { return encoder.encode(typeof get(h)).length; },
    js_typeof_copy(h, ptr, bufLen) { writeUtf8(typeof get(h), ptr, bufLen); },
    js_inspect_len(h) { return encoder.encode(inspectValue(get(h))).length; },
    js_inspect_copy(h, ptr, bufLen) { writeUtf8(inspectValue(get(h)), ptr, bufLen); },
    js_instanceof(instanceH, ctorH) {
      const ctor = get(ctorH);
      if (typeof ctor !== "function") return 0;
      try { return get(instanceH) instanceof ctor ? 1 : 0; }
      catch (_err) { return 0; }
    },
    js_make_callback(callbackId) {
      const wrapper = (...args) => {
        if (debug.trace) console.log(`[trace] wrapper id=${callbackId} fired with`, args);
        const argsHandle = alloc(args);
        try { instance.exports.js_bridge_invoke_proc(callbackId, argsHandle); }
        finally { release(argsHandle); }
      };
      return alloc(wrapper);
    },
  };

  // --- WASI ------------------------------------------------------------
  // Either the caller passed a custom `wasi` object (we use it as-is), or
  // we build a fresh wasi-preview1 implementation seeded from the same
  // options.
  const customWasi = options.wasi;
  const wasiImpl = customWasi ? null : createWasiPreview1({
    env: options.env,
    args: options.args,
    stdin: options.stdin,
    fs: options.fs,
  });
  const wasiImports = customWasi ?? wasiImpl.imports;

  // --- Instantiate -------------------------------------------------------
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

  // --- Build VM handle ---------------------------------------------------
  function evalRuby(source) {
    const handle = alloc(source);
    try { return instance.exports.js_bridge_eval_handle(handle); }
    finally { release(handle); }
  }

  return {
    instance,
    eval: evalRuby,
    fs:    customWasi ? undefined : wasiImpl.fs,
    env:   customWasi ? undefined : wasiImpl.env,
    args:  customWasi ? undefined : wasiImpl.args,
    stdin: customWasi ? undefined : wasiImpl.stdin,
    alloc, get, release,
    handleCount: () => handles.length - 1 - free.length,
  };
}
