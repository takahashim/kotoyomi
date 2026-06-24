// JS host adapter for the mruby-wasm-js mrbgem.
//
// Provides the JS core via a single factory:
//
//   import { createVM, Directory, File } from "mruby-wasm-js";
//
//   const vm = await createVM({
//     wasm: "/path/to/mruby-js.wasm",
//     env: { LOCALE: "ja" },
//     fs: new Directory({ "data": new Directory({ "poem.vtt": new File(bytes) }) }),
//   });
//
//   vm.eval('puts ENV["LOCALE"]');
//   vm.evalScript('#ruby-source');   // eval textContent of <script id="ruby-source">
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
//   - createJsImports({…}): builds the 25 js.* methods
//   - createVM(options):          orchestrator — creates state,
//                                  builds imports, instantiates wasm,
//                                  runs _start, returns VM handle.

import { createWasiPreview1, createFsFacade, Directory, File } from "./wasi-preview1.js";
import { createMemoryHelpers, encoder } from "./_memory.js";
import { debug } from "./debug.js";

export { Directory, File, createFsFacade, debug };

/**
 * Thrown by `vm.eval` / `vm.loadBytecode` / `vm.evalScript` when mruby
 * raises an unhandled exception. The fields mirror what mruby itself
 * exposes — `rubyClass` is `exc.class.name`, `backtrace` is what
 * `exc.backtrace` returned (file:line:in method, one entry per frame).
 *
 * Stack is best-effort: the JS engine's own stack trace shows where
 * `vm.eval` was called from; the Ruby backtrace is the real one.
 */
export class RubyError extends Error {
  constructor({ class: rubyClass, message, backtrace } = {}) {
    super(message || rubyClass || "mruby exception");
    this.name = "RubyError";
    this.rubyClass = rubyClass || "Exception";
    this.backtrace = Array.isArray(backtrace) ? backtrace : [];
  }
}

// `env` import object for instantiateStreaming. Empty in current builds:
// the gem's mruby-js.wasm uses hal-wasi-io (mrbgem/hal-wasi-io/) for the
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
 *  pending, it becomes a JS::Error on the Ruby side. Non-Error
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

/** Build the 25 `js.*` import methods, closing over the supplied
 *  per-VM state. Splitting this out from createVM means the imports can
 *  be unit-tested or rebuilt independently of the wasm fetch/instantiate
 *  cycle. */
function createJsImports({ handles, errorSlot, getInstance }) {
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
        try {
          // js_invoke_proc returns a fresh handle for the block's return
          // value (0 = undefined). We own it, so read + release.
          const resultHandle = getInstance().exports.js_invoke_proc(callbackId, argsHandle);
          if (resultHandle === 0) return undefined;
          const result = handles.get(resultHandle);
          handles.release(resultHandle);
          return result;
        } finally { handles.release(argsHandle); }
      };
      return handles.alloc(wrapper);
    },
    js_clone(h) {
      // Fresh handle pointing at the same JS value — used so JS-bound
      // copies don't share ownership with Ruby's original handle.
      if (h === 0) return 0;
      return handles.alloc(handles.get(h));
    },
  };
}

// --- Public factory -------------------------------------------------------

/**
 * Instantiate a fresh mruby VM and return a handle for driving it.
 *
 * @param {object} options
 * @param {string} options.wasm                  URL to mruby-js.wasm
 * @param {Record<string, string>} [options.env] initial ENV
 * @param {string[]} [options.args]              initial ARGV (defaults to ["mruby-wasm-js"])
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
 *   eval: (source: string) => number,           // 0 on success, 1 on parse/runtime error. Throws NotImplementedError in compiler-less builds.
 *   loadBytecode: (bytes: Uint8Array | ArrayBuffer) => number,  // load pre-compiled mrbc bytecode. 0 on success, 1 on runtime error.
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
 *       wasm: "/path/to/mruby-js.wasm",
 *       wasi: wasi.wasiImport,
 *       onStart: (instance) => wasi.start(instance),
 *     });
 *
 * The `js.*` imports (the JS layer itself) are always
 * provided by this adapter regardless of which WASI is used.
 */
export async function createVM(options = {}) {
  const { wasm, onStart } = options;
  if (!wasm) throw new Error("createVM: options.wasm (URL to mruby-js.wasm) is required");

  const handles = createHandleTable();
  const errorSlot = createErrorSlot();
  let instance = null;
  const getInstance = () => instance;

  const jsImports = createJsImports({ handles, errorSlot, getInstance });

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
    js: jsImports,
    wasi_snapshot_preview1: wasiImports,
  });
  instance = result.instance;
  if (wasiImpl) wasiImpl.bindInstance(instance);

  if (onStart) {
    onStart(instance);
  } else if (typeof instance.exports._initialize === "function") {
    // Reactor module: runs ctors (including the gem's mrb_open + ARGV
    // boot ctor) and returns. No exit-pseudo-exception to catch.
    instance.exports._initialize();
  } else if (typeof instance.exports._start === "function") {
    // Command module fallback (e.g. caller-supplied wasm built without
    // -mexec-model=reactor). _start can throw a pseudo-exception on exit;
    // swallow that one path and let real errors propagate.
    try { instance.exports._start(); }
    catch (err) {
      if (err.message && !err.message.includes("exit")) throw err;
    }
  }

  // Pull the structured exception left by the previous failing eval /
  // loadBytecode and surface it as a RubyError. The wasm side stashes a
  // JS object handle in g_last_error_handle when mrb->exc is set; we
  // drain + release it here. Returns null when no error is pending
  // (e.g., a parse fail before mruby ever got to raise).
  function takeRubyError() {
    const h = instance.exports.js_take_last_error();
    if (!h) return null;
    const info = handles.get(h);
    handles.release(h);
    return info ? new RubyError(info) : null;
  }

  function evalRuby(source, options = {}) {
    const { filename, lineOffset = 0, throw: shouldThrow = true } = options;
    const srcH = handles.alloc(source);
    const fileH = filename ? handles.alloc(String(filename)) : 0;
    let rc;
    try {
      rc = instance.exports.js_eval_handle(srcH, fileH, lineOffset | 0);
    } finally {
      handles.release(srcH);
      if (fileH) handles.release(fileH);
    }
    // rc === 2: compiler-less build signalled that source eval is not
    // available. Surface as NotImplementedError so the caller learns to
    // pre-compile with mrbc and use loadBytecode instead.
    if (rc === 2) {
      const err = new Error(
        "vm.eval(source) is not available in this mruby build " +
        "(compiled without mruby-compiler). Pre-compile with mrbc and use vm.loadBytecode(bytes) instead.",
      );
      err.name = "NotImplementedError";
      throw err;
    }
    if (rc !== 0 && shouldThrow) {
      const err = takeRubyError();
      if (err) throw err;
      throw new Error("mruby eval failed with no structured error info");
    }
    // throw: false branch — keep the legacy rc=0/1 contract and let the
    // caller decide whether to inspect the (now-drained) error slot.
    if (!shouldThrow && rc !== 0) takeRubyError();
    return rc;
  }

  // Load pre-compiled mruby bytecode (output of `mrbc`). The bytes must
  // already contain whatever fiber wrapping the source needs — this path
  // does NOT auto-wrap, unlike `eval(source)`. Available in all build
  // variants; primary use is the compiler-less / production variant.
  //
  // Accepts `Uint8Array` or `ArrayBuffer` (auto-wrapped as a zero-copy
  // view), since `await fetch(...).arrayBuffer()` returns the latter.
  function loadBytecode(bytes, options = {}) {
    if (bytes instanceof ArrayBuffer) bytes = new Uint8Array(bytes);
    if (!(bytes instanceof Uint8Array)) {
      throw new TypeError("loadBytecode: expected Uint8Array or ArrayBuffer");
    }
    const { throw: shouldThrow = true } = options;
    const handle = handles.alloc(bytes);
    let rc;
    try { rc = instance.exports.js_load_irep_handle(handle); }
    finally { handles.release(handle); }
    if (rc !== 0 && shouldThrow) {
      const err = takeRubyError();
      if (err) throw err;
      throw new Error("mruby loadBytecode failed with no structured error info");
    }
    if (!shouldThrow && rc !== 0) takeRubyError();
    return rc;
  }

  // Eval the textContent of a DOM element matched by `selector`.
  // Pairs with `<script type="text/ruby">` blocks. Browser-only.
  function evalScript(selector, options = {}) {
    if (typeof document === "undefined") {
      throw new Error("evalScript: requires a DOM (document is undefined)");
    }
    const el = document.querySelector(selector);
    if (!el) throw new Error(`evalScript: no element matches ${JSON.stringify(selector)}`);
    return evalRuby(el.textContent, options);
  }

  // Core VM surface plus, when we own the WASI side, the bundled VFS
  // state (fs / env / args / stdin). Keys are omitted entirely when
  // the caller passed their own `wasi` — that object controls fs/env/
  // args/stdin, and `undefined` placeholders are harder to typecheck
  // and easier to misread than absent properties.
  return {
    instance,
    eval: evalRuby,
    loadBytecode,
    evalScript,
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
