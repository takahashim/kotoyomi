// JS host adapter for the mruby-js-bridge mrbgem.
//
// Provides:
//   - Handle table for JS values exposed to Ruby
//   - Implementation of all js_bridge.* imports the mrbgem declares
//   - Boot helpers to instantiate the WASM, run an mruby program, and
//     route stdout/stderr to console.log.

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

// Debug toggle for the [trace] handle/callback logs. Set to true to
// inspect handle release timing and callback dispatch (was always-on
// during the Phase 2c spike). Off by default — production noise.
export const debug = { trace: false };

// Latest JS exception caught by a primitive. The C side calls
// js_take_error() right after each potentially-throwing op; if a handle
// is returned, mruby raises JSBridge::Error with the message string.
let pendingError = null;

function captureError(err) {
  pendingError = err;
}

// --- WASI configuration ----------------------------------------------------
// Populate these BEFORE calling boot() to expose env vars and a virtual
// filesystem to mruby:
//
//   import { boot, env, fs } from "<gem>/js/adapter.js";
//   env.HOME = "/home/user";
//   env.TZ   = "UTC";
//   fs.set("/data/poem.vtt", new TextEncoder().encode("WEBVTT\n..."));
//   await boot("./mruby.wasm");
//   evalRuby('puts ENV["TZ"];  puts File.read("/data/poem.vtt")');
//
// The VFS is read-only and lives entirely in memory; ideal for shipping
// fixed assets with the wasm. There is exactly one preopen at "/" — every
// path lookup is relative to that.

/** Environment variables visible to Ruby's `ENV` / wasi-libc's getenv. */
export const env = {};

/** Command-line arguments visible to Ruby's `ARGV` / C's `argv`. The
 *  first entry is conventionally the program name. main/main.c pushes
 *  args[1..] into Ruby's ARGV. */
export const args = ["mruby-js-bridge"];

/** stdin buffer. `bytes` is consumed by fd_read on fd 0; assign to it
 *  (or use `pushText`) before / between evalRuby calls.
 *
 *    stdin.pushText("first line\n")
 *    evalRuby('puts STDIN.gets')   # => "first line"
 */
export const stdin = {
  bytes: new Uint8Array(0),
  pushText(text) {
    const add = encoder.encode(text);
    const merged = new Uint8Array(this.bytes.length + add.length);
    merged.set(this.bytes);
    merged.set(add, this.bytes.length);
    this.bytes = merged;
  },
};

/** Virtual read-only filesystem. Map of absolute path → Uint8Array. */
export const fs = new Map();

const PREOPEN_FD = 3;
const PREOPEN_PATH = "/";
let nextFileFd = 4;
const openFiles = new Map(); // fd → { path, pos }

function resolvePath(rel) {
  // wasi-libc gives paths relative to the preopen dir. Stick the
  // preopen prefix back on and collapse any "//" to "/".
  return (PREOPEN_PATH + "/" + rel).replace(/\/+/g, "/");
}

// Write a 64-byte WASI filestat record. Only fields we care about (size,
// filetype, nlink) are filled; timestamps and dev/ino stay 0.
function writeFilestat(view, ptr, size) {
  for (let i = 0; i < 64; i++) view.setUint8(ptr + i, 0);
  view.setUint8(ptr + 16, 4);                            // filetype = regular_file
  view.setBigUint64(ptr + 24, 1n, true);                 // nlink
  view.setBigUint64(ptr + 32, BigInt(size), true);       // size
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

// --- WASI shim --------------------------------------------------------------
// Minimal WASI fd_write so `puts` from mruby maps to console.log.
const stdoutBuffer = [];
const wasiImports = {
  fd_write(fd, iovsPtr, iovsLen, nwrittenPtr) {
    const memory = instance.exports.memory;
    const view = new DataView(memory.buffer);
    let total = 0;
    for (let i = 0; i < iovsLen; i++) {
      const ptr = view.getUint32(iovsPtr + i * 8, true);
      const len = view.getUint32(iovsPtr + i * 8 + 4, true);
      const bytes = new Uint8Array(memory.buffer, ptr, len);
      const str = decoder.decode(bytes);
      stdoutBuffer.push(str);
      if (str.includes("\n")) {
        const joined = stdoutBuffer.join("");
        stdoutBuffer.length = 0;
        for (const line of joined.split("\n")) {
          if (line.length > 0) console.log("[mruby]", line);
        }
      }
      total += len;
    }
    view.setUint32(nwrittenPtr, total, true);
    return 0;
  },
  fd_close(fd) {
    if (openFiles.has(fd)) openFiles.delete(fd);
    return 0;
  },
  fd_seek(fd, offset /* BigInt */, whence, newOffsetPtr) {
    const f = openFiles.get(fd);
    if (!f) return 8; // EBADF — stdio not seekable here
    const data = fs.get(f.path);
    if (!data) return 8;
    const off = Number(offset);
    let newPos;
    switch (whence) {
      case 0: newPos = off; break;               // WHENCE_SET
      case 1: newPos = f.pos + off; break;       // WHENCE_CUR
      case 2: newPos = data.length + off; break; // WHENCE_END
      default: return 28;                        // EINVAL
    }
    if (newPos < 0) return 28;
    f.pos = newPos;
    const view = new DataView(instance.exports.memory.buffer);
    view.setBigUint64(newOffsetPtr, BigInt(newPos), true);
    return 0;
  },
  fd_tell(fd, ptr) {
    const f = openFiles.get(fd);
    if (!f) return 8;
    const view = new DataView(instance.exports.memory.buffer);
    view.setBigUint64(ptr, BigInt(f.pos), true);
    return 0;
  },
  fd_fdstat_get(_fd, fdstatPtr) {
    const view = new DataView(instance.exports.memory.buffer);
    for (let off = 0; off < 24; off++) view.setUint8(fdstatPtr + off, 0);
    return 0;
  },
  fd_fdstat_set_flags(_fd, _flags) { return 0; },
  fd_filestat_get(fd, ptr) {
    const view = new DataView(instance.exports.memory.buffer);
    const f = openFiles.get(fd);
    if (f) {
      const data = fs.get(f.path);
      if (!data) return 8;
      writeFilestat(view, ptr, data.length);
      return 0;
    }
    if (fd === 0 || fd === 1 || fd === 2) {
      // stdio = char device, size 0
      for (let i = 0; i < 64; i++) view.setUint8(ptr + i, 0);
      view.setUint8(ptr + 16, 2); // filetype_character_device
      return 0;
    }
    return 8;
  },
  fd_prestat_get(fd, ptr) {
    if (fd !== PREOPEN_FD) return 8; // EBADF — terminates wasi-libc preopen scan
    const view = new DataView(instance.exports.memory.buffer);
    const nameBytes = encoder.encode(PREOPEN_PATH);
    view.setUint8(ptr, 0);                                 // tag = preopentype_dir
    view.setUint32(ptr + 4, nameBytes.length, true);
    return 0;
  },
  fd_prestat_dir_name(fd, ptr, len) {
    if (fd !== PREOPEN_FD) return 8;
    const memory = new Uint8Array(instance.exports.memory.buffer);
    const nameBytes = encoder.encode(PREOPEN_PATH);
    const n = Math.min(nameBytes.length, len);
    memory.set(nameBytes.subarray(0, n), ptr);
    return 0;
  },
  fd_read(fd, iovsPtr, iovsLen, nreadPtr) {
    if (debug.trace) console.log(`[wasi] fd_read fd=${fd} iovsLen=${iovsLen}`);
    const view = new DataView(instance.exports.memory.buffer);
    const memory = new Uint8Array(instance.exports.memory.buffer);
    if (fd === 0) {
      // stdin: consume from the JS-side buffer. Returns 0 (EOF) when empty.
      let total = 0;
      for (let i = 0; i < iovsLen; i++) {
        const ptr = view.getUint32(iovsPtr + i * 8, true);
        const len = view.getUint32(iovsPtr + i * 8 + 4, true);
        const remaining = stdin.bytes.length;
        if (remaining <= 0) break;
        const n = Math.min(len, remaining);
        memory.set(stdin.bytes.subarray(0, n), ptr);
        stdin.bytes = stdin.bytes.subarray(n);
        total += n;
      }
      view.setUint32(nreadPtr, total, true);
      return 0;
    }
    const f = openFiles.get(fd);
    if (!f) {
      if (debug.trace) console.log(`[wasi] fd_read EBADF fd=${fd}`);
      return 8;
    }
    const data = fs.get(f.path);
    if (!data) return 8;
    let total = 0;
    for (let i = 0; i < iovsLen; i++) {
      const ptr = view.getUint32(iovsPtr + i * 8, true);
      const len = view.getUint32(iovsPtr + i * 8 + 4, true);
      const remaining = data.length - f.pos;
      if (remaining <= 0) break;
      const n = Math.min(len, remaining);
      memory.set(data.subarray(f.pos, f.pos + n), ptr);
      f.pos += n;
      total += n;
    }
    view.setUint32(nreadPtr, total, true);
    return 0;
  },
  path_open(dirfd, _dirflags, pathPtr, pathLen,
            _oflags, _rightsBase /* i64 BigInt */, _rightsInh /* i64 BigInt */,
            _fdflags, fdPtr) {
    if (debug.trace) console.log(`[wasi] path_open dirfd=${dirfd} path="${readUtf8(pathPtr, pathLen)}" fdPtr=${fdPtr}`);
    if (dirfd !== PREOPEN_FD) return 8;
    const relPath = readUtf8(pathPtr, pathLen);
    const fullPath = resolvePath(relPath);
    if (!fs.has(fullPath)) {
      if (debug.trace) console.log(`[wasi] path_open ENOENT: ${fullPath}`);
      return 44; // ENOENT
    }
    const fd = nextFileFd++;
    openFiles.set(fd, { path: fullPath, pos: 0 });
    const view = new DataView(instance.exports.memory.buffer);
    view.setUint32(fdPtr, fd, true);
    if (debug.trace) console.log(`[wasi] path_open OK: ${fullPath} → fd=${fd}`);
    return 0;
  },
  path_filestat_get(dirfd, _flags, pathPtr, pathLen, ptr) {
    if (dirfd !== PREOPEN_FD) return 8;
    const relPath = readUtf8(pathPtr, pathLen);
    const data = fs.get(resolvePath(relPath));
    if (!data) return 44;
    writeFilestat(new DataView(instance.exports.memory.buffer), ptr, data.length);
    return 0;
  },
  proc_exit(code) {
    console.log("[mruby] proc_exit", code);
  },
  // env vars ----------------------------------------------------------------
  environ_sizes_get(countPtr, sizesPtr) {
    const view = new DataView(instance.exports.memory.buffer);
    const entries = Object.entries(env);
    let totalSize = 0;
    for (const [k, v] of entries) totalSize += encoder.encode(`${k}=${v}\0`).length;
    view.setUint32(countPtr, entries.length, true);
    view.setUint32(sizesPtr, totalSize, true);
    return 0;
  },
  environ_get(envPtr, bufPtr) {
    const view = new DataView(instance.exports.memory.buffer);
    const memory = new Uint8Array(instance.exports.memory.buffer);
    let offset = bufPtr;
    Object.entries(env).forEach(([k, v], i) => {
      view.setUint32(envPtr + i * 4, offset, true);
      const bytes = encoder.encode(`${k}=${v}\0`);
      memory.set(bytes, offset);
      offset += bytes.length;
    });
    return 0;
  },
  // command-line args ------------------------------------------------------
  args_sizes_get(countPtr, sizesPtr) {
    const view = new DataView(instance.exports.memory.buffer);
    let totalSize = 0;
    for (const a of args) totalSize += encoder.encode(`${a}\0`).length;
    view.setUint32(countPtr, args.length, true);
    view.setUint32(sizesPtr, totalSize, true);
    return 0;
  },
  args_get(argvPtr, bufPtr) {
    const view = new DataView(instance.exports.memory.buffer);
    const memory = new Uint8Array(instance.exports.memory.buffer);
    let offset = bufPtr;
    args.forEach((a, i) => {
      view.setUint32(argvPtr + i * 4, offset, true);
      const bytes = encoder.encode(`${a}\0`);
      memory.set(bytes, offset);
      offset += bytes.length;
    });
    return 0;
  },
  // clock -------------------------------------------------------------------
  clock_time_get(id, _precision, ptr) {
    const view = new DataView(instance.exports.memory.buffer);
    let nanos;
    if (id === 0) {
      // CLOCK_REALTIME — Date.now() is ms since epoch, scale to ns
      nanos = BigInt(Math.floor(Date.now() * 1e6));
    } else {
      // monotonic / process_cputime / thread_cputime — performance.now
      const now = (typeof performance !== "undefined" ? performance.now() : Date.now());
      nanos = BigInt(Math.floor(now * 1e6));
    }
    view.setBigUint64(ptr, nanos, true);
    return 0;
  },
  clock_res_get(_id, ptr) {
    // 1ms resolution (Date.now / performance.now in JS)
    const view = new DataView(instance.exports.memory.buffer);
    view.setBigUint64(ptr, 1_000_000n, true);
    return 0;
  },
  // random ------------------------------------------------------------------
  random_get(ptr, len) {
    const memory = new Uint8Array(instance.exports.memory.buffer, ptr, len);
    // crypto.getRandomValues caps at 65536 bytes per call
    for (let off = 0; off < len; off += 65536) {
      const slice = memory.subarray(off, Math.min(off + 65536, len));
      crypto.getRandomValues(slice);
    }
    return 0;
  },
  // unimplemented (not exercised in current scope) — return ENOSYS-ish ------
  fd_filestat_set_size(_fd, _size) { return 28; },
  fd_filestat_set_times(_fd, _atim, _mtim, _flags) { return 28; },
  fd_pread(_fd, _iovs, _iovsLen, _offset, _nreadPtr) { return 28; },
  fd_pwrite(_fd, _iovs, _iovsLen, _offset, _nwrittenPtr) { return 28; },
  fd_readdir(_fd, _buf, _bufLen, _cookie, _bufused) { return 28; },
  fd_renumber(_from, _to) { return 28; },
  fd_sync(_fd) { return 0; },
  fd_advise(_fd, _offset, _len, _advice) { return 0; },
  fd_allocate(_fd, _offset, _len) { return 28; },
  fd_datasync(_fd) { return 0; },
  path_create_directory(_fd, _path, _pathLen) { return 28; },
  path_filestat_set_times() { return 28; },
  path_link() { return 28; },
  path_readlink() { return 28; },
  path_remove_directory() { return 28; },
  path_rename() { return 28; },
  path_symlink() { return 28; },
  path_unlink_file() { return 28; },
  poll_oneoff() { return 28; },
  sched_yield() { return 0; },
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
export async function boot(wasmUrl) {
  const response = await fetch(wasmUrl);
  if (!response.ok) {
    throw new Error(`Failed to fetch ${wasmUrl}: ${response.status}`);
  }
  const result = await WebAssembly.instantiateStreaming(response, {
    env: envImports,
    js_bridge: jsBridgeImports,
    wasi_snapshot_preview1: wasiImports,
  });
  instance = result.instance;
  if (typeof instance.exports._start === "function") {
    try {
      instance.exports._start();
    } catch (err) {
      if (err.message && !err.message.includes("exit")) throw err;
    }
  }
  return instance;
}
