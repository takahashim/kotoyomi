// WASI preview1 implementation (in-memory) for mruby-js-bridge.
//
// Bundled with the gem as the default `boot(url, { wasi })` impl.
// Users who need richer features (tree VFS, fd_readdir, OPFS bindings,
// multiple preopens, ...) can swap this out for
// `@bjorn3/browser_wasi_shim` or any other preview1-compatible
// implementation — see boot()'s JSDoc in adapter.js.
//
// Host-side configuration (env / args / stdin / fs) is exported so the
// caller can populate it before boot:
//
//   import { boot, env, fs } from "<gem>/js/adapter.js";
//   env.HOME = "/home/user";
//   fs.set("/data/poem.vtt", new TextEncoder().encode("..."));
//   await boot(url);
//   evalRuby('puts ENV["HOME"]; puts File.read("/data/poem.vtt")');

import { debug } from "./debug.js";

const decoder = new TextDecoder("utf-8");
const encoder = new TextEncoder();

// --- WASI preview1 constants ----------------------------------------------
// Subsets of the preview1 ABI the in-memory impl actually inspects.
// Keeping these named avoids scattering 1/4/8/20/28/44 across the
// imports — names track the wasi-libc / WASI spec.
//
// path_open oflags
const O_CREAT     = 1;
const O_DIRECTORY = 2;
const O_EXCL      = 4;
const O_TRUNC     = 8;
// path_open / fd_fdstat fdflags
const FD_APPEND = 1;
// fd_seek whence
const WHENCE_SET = 0;
const WHENCE_CUR = 1;
const WHENCE_END = 2;
// preview1 errno values we actually return
const E_BADF     = 8;
const E_EXIST    = 20;
const E_INVAL    = 28;
const E_ISDIR    = 31;
const E_NOENT    = 44;
const E_NOTDIR   = 54;
const E_NOTEMPTY = 55;
// filetype values written into filestat records
const FILETYPE_CHARACTER_DEVICE = 2;
const FILETYPE_DIRECTORY        = 3;
const FILETYPE_REGULAR_FILE     = 4;

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

// --- Tree VFS --------------------------------------------------------------
// Internal storage is a tree of `File` and `Directory` nodes. The `fs`
// object below presents a Map-compatible facade (set/get/has/delete +
// iteration) so existing code that does `fs.set("/data/poem.vtt", bytes)`
// keeps working unchanged — `set` walks path segments and auto-creates
// intermediate Directory nodes on demand.
//
// Power users can also construct a tree declaratively and hand it over
// in one shot via `fs.populate(new Directory({ ... }))`.

/** A regular-file node in the VFS. Holds raw bytes; no path stored
 *  (the path is implicit from the parent Directory's entries map). */
export class File {
  constructor(data = new Uint8Array(0)) {
    this.data = data;
  }
}

/** A directory node in the VFS. `entries` maps name → File | Directory. */
export class Directory {
  constructor(entries = {}) {
    this.entries = entries;
  }
}

const root = new Directory();

// Normalise an absolute path to an array of segments. Empty + "."
// segments are dropped, ".." pops the previous segment. Lets wasi-libc
// pass paths like "." (preopen-relative for "/") or "data/.." through
// the tree walker correctly.
function pathSegments(absPath) {
  const out = [];
  for (const seg of absPath.split("/")) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") out.pop();
    else out.push(seg);
  }
  return out;
}

// Walk an absolute path. Returns one of:
//   { parent, name, node }     — node is the resolved File|Directory or null if missing
//   { parent: null, name: "", node: root }  — root itself
//   null                       — traversal hit a File mid-path (caller maps to E_NOTDIR)
function lookupFull(absPath) {
  const segs = pathSegments(absPath);
  if (segs.length === 0) return { parent: null, name: "", node: root };
  let dir = root;
  for (let i = 0; i < segs.length - 1; i++) {
    const next = dir.entries[segs[i]];
    if (next == null) {
      return { parent: dir, name: segs[segs.length - 1], node: null };
    }
    if (!(next instanceof Directory)) return null;
    dir = next;
  }
  const leaf = segs[segs.length - 1];
  return { parent: dir, name: leaf, node: dir.entries[leaf] ?? null };
}

function lookupNode(absPath) {
  const r = lookupFull(absPath);
  return r ? r.node : null;
}

// Walk `relPath` from `baseDir`, returning the resolved File | Directory
// node or null on miss. "." segments are skipped; ".." is treated as
// "stay put" because we don't track parent pointers (good enough for
// readdir's fstatat lookups, which only ever ask about "." and direct
// child names).
function resolveRelative(baseDir, relPath) {
  const segs = relPath.split("/").filter((s) => s.length > 0 && s !== ".");
  let node = baseDir;
  for (const seg of segs) {
    if (seg === "..") continue;
    if (!(node instanceof Directory)) return null;
    node = node.entries[seg] ?? null;
    if (!node) return null;
  }
  return node;
}

// Walk to (or create) the parent Directory of absPath. Auto-creates
// intermediate Directory nodes; throws if any intermediate is a File.
function ensureParent(absPath) {
  const segs = pathSegments(absPath);
  if (segs.length === 0) throw new Error("cannot ensure parent of root");
  let dir = root;
  for (let i = 0; i < segs.length - 1; i++) {
    const name = segs[i];
    let next = dir.entries[name];
    if (next == null) {
      next = new Directory();
      dir.entries[name] = next;
    } else if (!(next instanceof Directory)) {
      throw new Error(`cannot create '${absPath}': '${name}' is a file`);
    }
    dir = next;
  }
  return { parent: dir, leaf: segs[segs.length - 1] };
}

// Walk all File leaves yielding [absolutePath, bytes] pairs.
function* walkFiles(prefix, dir) {
  for (const [name, node] of Object.entries(dir.entries)) {
    const path = prefix + "/" + name;
    if (node instanceof File) {
      yield [path, node.data];
    } else {
      yield* walkFiles(path, node);
    }
  }
}

/** Map-compatible virtual filesystem facade. Backed by a tree of
 *  File / Directory nodes; `set(path, bytes)` auto-creates intermediate
 *  directories. Iteration yields only File leaves (not directories). */
export const fs = {
  set(path, bytes) {
    const { parent, leaf } = ensureParent(path);
    const existing = parent.entries[leaf];
    if (existing instanceof Directory) {
      throw new Error(`cannot set '${path}': it's a directory`);
    }
    if (existing instanceof File) {
      existing.data = bytes;
    } else {
      parent.entries[leaf] = new File(bytes);
    }
    return this;
  },
  get(path) {
    const node = lookupNode(path);
    return node instanceof File ? node.data : undefined;
  },
  has(path) {
    return lookupNode(path) instanceof File;
  },
  delete(path) {
    const r = lookupFull(path);
    if (!r || !(r.node instanceof File) || !r.parent) return false;
    delete r.parent.entries[r.name];
    return true;
  },
  *entries() {
    yield* walkFiles("", root);
  },
  *keys() {
    for (const [p] of this.entries()) yield p;
  },
  *values() {
    for (const [, v] of this.entries()) yield v;
  },
  [Symbol.iterator]() {
    return this.entries();
  },
  get size() {
    let n = 0;
    for (const _ of this.entries()) n++;
    return n;
  },
  clear() {
    root.entries = {};
  },
  /** Replace the entire tree with `dir`. Useful for declarative setup:
   *
   *    fs.populate(new Directory({
   *      "data": new Directory({ "poem.vtt": new File(bytes) }),
   *    }));
   */
  populate(dir) {
    if (!(dir instanceof Directory)) {
      throw new TypeError("fs.populate expects a Directory");
    }
    root.entries = dir.entries;
  },
  /** Direct access to the underlying root Directory (for inspection or
   *  manipulation that the Map facade doesn't cover, e.g. creating an
   *  empty subdirectory programmatically). */
  get root() {
    return root;
  },
};

const PREOPEN_FD = 3;
const PREOPEN_PATH = "/";
let nextFileFd = 4;
// fd → { type: 'file', path, pos, append } | { type: 'dir', node }
// (file fds carry a path + cursor; dir fds carry a Directory node ref)
const openFiles = new Map();

// The wasm instance is bound by `bindInstance()` from adapter.js's boot()
// so the WASI imports can read linear memory. Stays null if a caller
// passes their own WASI to boot() and never reaches these imports.
let instance = null;

/** Called by adapter.js's boot() right after instantiation, so the WASI
 *  imports below can dereference linear memory. Safe to call repeatedly. */
export function bindInstance(inst) {
  instance = inst;
}

function resolvePath(rel) {
  // wasi-libc gives paths relative to the preopen dir. Stick the
  // preopen prefix back on and collapse any "//" to "/".
  return (PREOPEN_PATH + "/" + rel).replace(/\/+/g, "/");
}

// Write a 64-byte WASI filestat record. Only fields we care about
// (filetype, nlink, size) are filled; timestamps and dev/ino stay 0.
function writeFilestat(view, ptr, filetype, size) {
  for (let i = 0; i < 64; i++) view.setUint8(ptr + i, 0);
  view.setUint8(ptr + 16, filetype);
  view.setBigUint64(ptr + 24, 1n, true);                 // nlink
  view.setBigUint64(ptr + 32, BigInt(size), true);       // size
}

function readUtf8(ptr, len) {
  const memory = instance.exports.memory;
  const bytes = new Uint8Array(memory.buffer, ptr, len);
  return decoder.decode(bytes);
}

// Sum the byte length across an iovec array (uint32 length lives at
// offset 4 of each 8-byte slot — ptr at offset 0, len at offset 4).
function iovsTotalLen(view, iovsPtr, iovsLen) {
  let total = 0;
  for (let i = 0; i < iovsLen; i++) total += view.getUint32(iovsPtr + i * 8 + 4, true);
  return total;
}

// fd_write helper: write the iovec contents into the in-memory file
// backing `f`. Grows the Uint8Array if needed, advances f.pos for
// non-append fds, returns the number of bytes written.
function writeToOpenFile(f, view, memory, iovsPtr, iovsLen) {
  const data = fs.get(f.path);
  const needed = iovsTotalLen(view, iovsPtr, iovsLen);
  const writeStart = f.append ? data.length : f.pos;
  const newSize = Math.max(data.length, writeStart + needed);
  let target = data;
  if (newSize > data.length) {
    target = new Uint8Array(newSize);
    target.set(data);
    fs.set(f.path, target);
  }
  let pos = writeStart;
  let total = 0;
  for (let i = 0; i < iovsLen; i++) {
    const ptr = view.getUint32(iovsPtr + i * 8, true);
    const len = view.getUint32(iovsPtr + i * 8 + 4, true);
    target.set(memory.subarray(ptr, ptr + len), pos);
    pos += len;
    total += len;
  }
  if (!f.append) f.pos = pos;
  return total;
}

// fd_read helper: drain bytes from the JS-side stdin buffer into the
// guest's iovec slots. Returns 0 (EOF) when the buffer is empty —
// matching POSIX read() semantics for an exhausted pipe.
function readFromStdin(view, memory, iovsPtr, iovsLen) {
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
  return total;
}

// fd_read helper: drain bytes from an open file's backing Uint8Array
// into the guest's iovec slots. Advances f.pos by the number of bytes
// actually transferred (capped by EOF). Returns -1 if the path was
// removed under us (caller maps to E_BADF).
function readFromOpenFile(f, view, memory, iovsPtr, iovsLen) {
  const data = fs.get(f.path);
  if (!data) return -1;
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
  return total;
}

// fd_write helper: drain iovec contents into a line-buffered console.
// fd 1/2 (and any unknown fd that isn't a tracked file) lands here so
// `puts` from mruby reaches console.log without spawning a real tty.
const stdoutBuffer = [];
function writeToStdio(view, memory, iovsPtr, iovsLen) {
  let total = 0;
  for (let i = 0; i < iovsLen; i++) {
    const ptr = view.getUint32(iovsPtr + i * 8, true);
    const len = view.getUint32(iovsPtr + i * 8 + 4, true);
    const str = decoder.decode(memory.subarray(ptr, ptr + len));
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
  return total;
}

// --- WASI imports ----------------------------------------------------------
export const wasiImports = {
  fd_write(fd, iovsPtr, iovsLen, nwrittenPtr) {
    const view = new DataView(instance.exports.memory.buffer);
    const memory = new Uint8Array(instance.exports.memory.buffer);
    const f = openFiles.get(fd);
    if (f && f.type === "dir") return E_ISDIR;
    const total = f
      ? writeToOpenFile(f, view, memory, iovsPtr, iovsLen)
      : writeToStdio(view, memory, iovsPtr, iovsLen);
    view.setUint32(nwrittenPtr, total, true);
    return 0;
  },
  fd_close(fd) {
    if (openFiles.has(fd)) openFiles.delete(fd);
    return 0;
  },
  fd_seek(fd, offset /* BigInt */, whence, newOffsetPtr) {
    const f = openFiles.get(fd);
    if (!f || f.type !== "file") return E_BADF; // stdio / dirs not seekable here
    const data = fs.get(f.path);
    if (!data) return E_BADF;
    const off = Number(offset);
    let newPos;
    switch (whence) {
      case WHENCE_SET: newPos = off; break;
      case WHENCE_CUR: newPos = f.pos + off; break;
      case WHENCE_END: newPos = data.length + off; break;
      default: return E_INVAL;
    }
    if (newPos < 0) return E_INVAL;
    f.pos = newPos;
    const view = new DataView(instance.exports.memory.buffer);
    view.setBigUint64(newOffsetPtr, BigInt(newPos), true);
    return 0;
  },
  fd_tell(fd, ptr) {
    const f = openFiles.get(fd);
    if (!f || f.type !== "file") return E_BADF;
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
    if (f && f.type === "file") {
      const data = fs.get(f.path);
      if (!data) return E_BADF;
      writeFilestat(view, ptr, FILETYPE_REGULAR_FILE, data.length);
      return 0;
    }
    if (f && f.type === "dir") {
      writeFilestat(view, ptr, FILETYPE_DIRECTORY, 0);
      return 0;
    }
    if (fd === 0 || fd === 1 || fd === 2) {
      writeFilestat(view, ptr, FILETYPE_CHARACTER_DEVICE, 0);
      return 0;
    }
    return E_BADF;
  },
  fd_prestat_get(fd, ptr) {
    if (fd !== PREOPEN_FD) return E_BADF; // terminates wasi-libc preopen scan
    const view = new DataView(instance.exports.memory.buffer);
    const nameBytes = encoder.encode(PREOPEN_PATH);
    view.setUint8(ptr, 0);                                 // tag = preopentype_dir
    view.setUint32(ptr + 4, nameBytes.length, true);
    return 0;
  },
  fd_prestat_dir_name(fd, ptr, len) {
    if (fd !== PREOPEN_FD) return E_BADF;
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
    let total;
    if (fd === 0) {
      total = readFromStdin(view, memory, iovsPtr, iovsLen);
    } else {
      const f = openFiles.get(fd);
      if (!f || f.type !== "file") {
        if (debug.trace) console.log(`[wasi] fd_read EBADF fd=${fd}`);
        return E_BADF;
      }
      total = readFromOpenFile(f, view, memory, iovsPtr, iovsLen);
      if (total < 0) return E_BADF;
    }
    view.setUint32(nreadPtr, total, true);
    return 0;
  },
  path_open(dirfd, _dirflags, pathPtr, pathLen,
            oflags, _rightsBase /* i64 BigInt */, _rightsInh /* i64 BigInt */,
            fdflags, fdPtr) {
    if (debug.trace) console.log(`[wasi] path_open dirfd=${dirfd} path="${readUtf8(pathPtr, pathLen)}" oflags=${oflags} fdflags=${fdflags}`);
    if (dirfd !== PREOPEN_FD) return E_BADF;
    const relPath = readUtf8(pathPtr, pathLen);
    const fullPath = resolvePath(relPath);

    const directory = !!(oflags & O_DIRECTORY);
    const create = !!(oflags & O_CREAT);
    const excl   = !!(oflags & O_EXCL);
    const trunc  = !!(oflags & O_TRUNC);
    const append = !!(fdflags & FD_APPEND);

    const node = lookupNode(fullPath);

    if (directory) {
      if (!node) return E_NOENT;
      if (!(node instanceof Directory)) return E_NOTDIR;
      const fd = nextFileFd++;
      openFiles.set(fd, { type: "dir", node });
      const view = new DataView(instance.exports.memory.buffer);
      view.setUint32(fdPtr, fd, true);
      if (debug.trace) console.log(`[wasi] path_open OK (dir): ${fullPath} → fd=${fd}`);
      return 0;
    }

    if (node instanceof Directory) return E_ISDIR;
    const exists = node instanceof File;
    if (excl && exists) return E_EXIST;
    if (!exists && !create) return E_NOENT;
    if (!exists || trunc) {
      fs.set(fullPath, new Uint8Array(0));
    }

    const data = fs.get(fullPath);
    const fd = nextFileFd++;
    openFiles.set(fd, { type: "file", path: fullPath, pos: append ? data.length : 0, append });
    const view = new DataView(instance.exports.memory.buffer);
    view.setUint32(fdPtr, fd, true);
    if (debug.trace) console.log(`[wasi] path_open OK: ${fullPath} → fd=${fd} (append=${append}, trunc=${trunc}, create=${create})`);
    return 0;
  },
  path_filestat_get(dirfd, _flags, pathPtr, pathLen, ptr) {
    // Accept either the preopen fd (paths absolute under "/") or an
    // open directory fd from a previous path_open(O_DIRECTORY) — wasi-libc's
    // readdir() calls fstatat(dirp->fd, name, ...) for each entry whose
    // d_ino is reported as zero, so we have to honour this case for
    // Dir.entries to surface anything to Ruby.
    let baseDir;
    if (dirfd === PREOPEN_FD) {
      baseDir = root;
    } else {
      const f = openFiles.get(dirfd);
      if (!f || f.type !== "dir") return E_BADF;
      baseDir = f.node;
    }
    const relPath = readUtf8(pathPtr, pathLen);
    const node = resolveRelative(baseDir, relPath);
    if (!node) return E_NOENT;
    const view = new DataView(instance.exports.memory.buffer);
    if (node instanceof Directory) {
      writeFilestat(view, ptr, FILETYPE_DIRECTORY, 0);
    } else {
      writeFilestat(view, ptr, FILETYPE_REGULAR_FILE, node.data.length);
    }
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
  // write-side filesystem ops ----------------------------------------------
  fd_filestat_set_size(fd, size /* i64 BigInt */) {
    const f = openFiles.get(fd);
    if (!f || f.type !== "file") return E_BADF;
    const data = fs.get(f.path);
    if (!data) return E_BADF;
    const newSize = Number(size);
    if (newSize < 0) return E_INVAL;
    if (newSize < data.length) {
      fs.set(f.path, data.slice(0, newSize));
    } else if (newSize > data.length) {
      const grown = new Uint8Array(newSize);
      grown.set(data);
      fs.set(f.path, grown);
    }
    return 0;
  },
  fd_pwrite(fd, iovsPtr, iovsLen, offset /* i64 BigInt */, nwrittenPtr) {
    const f = openFiles.get(fd);
    if (!f || f.type !== "file") return E_BADF;
    const view = new DataView(instance.exports.memory.buffer);
    const memory = new Uint8Array(instance.exports.memory.buffer);
    // Treat pwrite like a non-append write at an explicit offset, but
    // don't advance f.pos. We synthesize a one-shot pseudo-fd-state
    // pointing at the requested offset and reuse writeToOpenFile.
    const pseudo = { path: f.path, pos: Number(offset), append: false };
    const total = writeToOpenFile(pseudo, view, memory, iovsPtr, iovsLen);
    view.setUint32(nwrittenPtr, total, true);
    return 0;
  },
  path_unlink_file(dirfd, pathPtr, pathLen) {
    if (dirfd !== PREOPEN_FD) return E_BADF;
    const fullPath = resolvePath(readUtf8(pathPtr, pathLen));
    const node = lookupNode(fullPath);
    if (!node) return E_NOENT;
    if (node instanceof Directory) return E_ISDIR;
    fs.delete(fullPath);
    return 0;
  },
  path_create_directory(dirfd, pathPtr, pathLen) {
    if (dirfd !== PREOPEN_FD) return E_BADF;
    const fullPath = resolvePath(readUtf8(pathPtr, pathLen));
    const segs = pathSegments(fullPath);
    if (segs.length === 0) return E_EXIST; // root already exists
    let dir = root;
    for (let i = 0; i < segs.length - 1; i++) {
      const next = dir.entries[segs[i]];
      if (next == null) return E_NOENT;
      if (!(next instanceof Directory)) return E_NOTDIR;
      dir = next;
    }
    const leaf = segs[segs.length - 1];
    if (dir.entries[leaf] != null) return E_EXIST;
    dir.entries[leaf] = new Directory();
    return 0;
  },
  path_remove_directory(dirfd, pathPtr, pathLen) {
    if (dirfd !== PREOPEN_FD) return E_BADF;
    const fullPath = resolvePath(readUtf8(pathPtr, pathLen));
    const r = lookupFull(fullPath);
    if (!r || r.node == null) return E_NOENT;
    if (!(r.node instanceof Directory)) return E_NOTDIR;
    if (!r.parent) return E_INVAL; // can't rmdir root
    if (Object.keys(r.node.entries).length > 0) return E_NOTEMPTY;
    delete r.parent.entries[r.name];
    return 0;
  },

  // unimplemented (not exercised in current scope) — return EINVAL-ish -----
  fd_filestat_set_times(_fd, _atim, _mtim, _flags) { return E_INVAL; },
  fd_pread(_fd, _iovs, _iovsLen, _offset, _nreadPtr) { return E_INVAL; },
  fd_readdir(fd, bufPtr, bufLen, cookie /* BigInt */, bufusedPtr) {
    if (debug.trace) console.log(`[wasi] fd_readdir fd=${fd} bufLen=${bufLen} cookie=${cookie}`);
    const f = openFiles.get(fd);
    if (!f || f.type !== "dir") return E_BADF;
    const view = new DataView(instance.exports.memory.buffer);
    const memory = new Uint8Array(instance.exports.memory.buffer);
    // dirent layout (24 bytes header + name):
    //   u64 d_next (next cookie)  | u64 d_ino  | u32 d_namlen | u8 d_type | 3 padding
    // Synthesize "." / ".." at indices 0 / 1, real entries follow. CRuby
    // Dir.entries includes "." / ".." and code in the wild often expects them.
    const realNames = Object.keys(f.node.entries);
    const all = [".", "..", ...realNames];
    let bufPos = 0;
    for (let i = Number(cookie); i < all.length; i++) {
      const name = all[i];
      const nameBytes = encoder.encode(name);
      const recordSize = 24 + nameBytes.length;
      if (bufPos + recordSize > bufLen) break;
      // Zero the 24-byte header (covers padding too).
      for (let j = 0; j < 24; j++) view.setUint8(bufPtr + bufPos + j, 0);
      view.setBigUint64(bufPtr + bufPos, BigInt(i + 1), true);     // d_next
      // Set d_ino non-zero so wasi-libc's readdir trusts our value
      // and doesn't fall back to fstatat(dirfd, name) for the inode
      // (we don't actually track inodes; the value just has to be
      // non-zero per WASI convention).
      view.setBigUint64(bufPtr + bufPos + 8, BigInt(i + 1), true);  // d_ino
      view.setUint32(bufPtr + bufPos + 16, nameBytes.length, true); // d_namlen
      const child = i < 2 ? f.node : f.node.entries[name];
      view.setUint8(bufPtr + bufPos + 20,
        child instanceof Directory ? FILETYPE_DIRECTORY : FILETYPE_REGULAR_FILE);
      memory.set(nameBytes, bufPtr + bufPos + 24);
      bufPos += recordSize;
    }
    view.setUint32(bufusedPtr, bufPos, true);
    return 0;
  },
  fd_renumber(_from, _to) { return E_INVAL; },
  fd_sync(_fd) { return 0; },
  fd_advise(_fd, _offset, _len, _advice) { return 0; },
  fd_allocate(_fd, _offset, _len) { return E_INVAL; },
  fd_datasync(_fd) { return 0; },
  path_filestat_set_times() { return E_INVAL; },
  path_link() { return E_INVAL; },
  path_readlink() { return E_INVAL; },
  path_rename(oldDirfd, oldPathPtr, oldPathLen, newDirfd, newPathPtr, newPathLen) {
    if (oldDirfd !== PREOPEN_FD || newDirfd !== PREOPEN_FD) return E_BADF;
    const oldPath = resolvePath(readUtf8(oldPathPtr, oldPathLen));
    const newPath = resolvePath(readUtf8(newPathPtr, newPathLen));
    if (!fs.has(oldPath)) return E_NOENT;
    fs.set(newPath, fs.get(oldPath));
    fs.delete(oldPath);
    return 0;
  },
  path_symlink() { return E_INVAL; },
  poll_oneoff() { return E_INVAL; },
  sched_yield() { return 0; },
};
