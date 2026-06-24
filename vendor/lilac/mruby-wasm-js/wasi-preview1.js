// WASI preview1 implementation (in-memory) for mruby-wasm-js.
//
// `createWasiPreview1({ env, args, stdin, fs })` returns a fresh,
// independent WASI implementation with its own state — env vars, argv,
// stdin buffer, virtual filesystem, open-fd table. Used as the default
// `wasi_snapshot_preview1` import object by index.js's `createVM`,
// but also exportable for direct use.
//
// Internal layout:
//   - File / Directory: tree-VFS node classes (module-level)
//   - constants: WASI errno / oflags / fdflags / filetype values
//   - pure tree walkers: pathSegments / lookupFull / lookupNode /
//     ensureParent / walkFiles / resolveRelative — pass `root` as arg
//   - createFsFacade(root): Map-compatible facade over a Directory tree
//   - createWasiPreview1(options): orchestrator that holds per-VM state
//     (open fds, stdout buffer, instance ref) and returns the WASI
//     imports object plus VFS handles.

import { debug } from "./debug.js";
import { createMemoryHelpers, decoder, encoder } from "./_memory.js";

// --- Module-level types ---------------------------------------------------

/** A regular-file node in the VFS. Holds raw bytes; no path stored. */
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

// --- Constants ------------------------------------------------------------

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

const PREOPEN_FD = 3;
const PREOPEN_PATH = "/";

// --- Pure tree walkers ----------------------------------------------------
// All take `root` (or another Directory) as an explicit argument so they
// can be unit-tested independently of WASI imports / VM state.

// Normalise an absolute path to an array of segments. Empty + "."
// segments are dropped, ".." pops the previous segment.
function pathSegments(absPath) {
  const out = [];
  for (const seg of absPath.split("/")) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") out.pop();
    else out.push(seg);
  }
  return out;
}

function resolvePathToAbs(rel) {
  return (PREOPEN_PATH + "/" + rel).replace(/\/+/g, "/");
}

// Walk an absolute path. Returns one of:
//   { parent, name, node }     — node is the resolved File|Directory or null if missing
//   { parent: null, name: "", node: root }  — root itself
//   null                       — traversal hit a File mid-path (caller maps to E_NOTDIR)
function lookupFull(root, absPath) {
  const segs = pathSegments(absPath);
  if (segs.length === 0) return { parent: null, name: "", node: root };
  let dir = root;
  for (let i = 0; i < segs.length - 1; i++) {
    const next = dir.entries[segs[i]];
    if (next == null) return { parent: dir, name: segs[segs.length - 1], node: null };
    if (!(next instanceof Directory)) return null;
    dir = next;
  }
  const leaf = segs[segs.length - 1];
  return { parent: dir, name: leaf, node: dir.entries[leaf] ?? null };
}

function lookupNode(root, absPath) {
  const r = lookupFull(root, absPath);
  return r ? r.node : null;
}

// Walk to (or create) the parent Directory of absPath. Auto-creates
// intermediate Directory nodes; throws if any intermediate is a File.
function ensureParent(root, absPath) {
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
    if (node instanceof File) yield [path, node.data];
    else yield* walkFiles(path, node);
  }
}

// Walk relPath from baseDir; "." skipped, ".." treated as "stay put"
// (we don't track parent pointers — good enough for readdir's fstatat).
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

// --- Pure record writers --------------------------------------------------

// Write a 64-byte WASI filestat record. Only fields we care about
// (filetype, nlink, size) are filled; timestamps and dev/ino stay 0.
function writeFilestat(view, ptr, filetype, size) {
  for (let i = 0; i < 64; i++) view.setUint8(ptr + i, 0);
  view.setUint8(ptr + 16, filetype);
  view.setBigUint64(ptr + 24, 1n, true);
  view.setBigUint64(ptr + 32, BigInt(size), true);
}

// Sum the byte length across an iovec array (uint32 length lives at
// offset 4 of each 8-byte slot — ptr at offset 0, len at offset 4).
function iovsTotalLen(view, iovsPtr, iovsLen) {
  let total = 0;
  for (let i = 0; i < iovsLen; i++) total += view.getUint32(iovsPtr + i * 8 + 4, true);
  return total;
}

// --- Public: fs Map facade factory ----------------------------------------

/**
 * Build a Map-compatible facade over a `Directory` tree. Exposes
 * set / get / has / delete / iteration / clear / size / Symbol.iterator
 * plus `populate(dir)` and `root`. Iteration yields only File leaves
 * in tree-traversal order. `set` auto-creates intermediate Directory
 * nodes on demand.
 */
export function createFsFacade(root) {
  return {
    set(path, bytes) {
      const { parent, leaf } = ensureParent(root, path);
      const existing = parent.entries[leaf];
      if (existing instanceof Directory) {
        throw new Error(`cannot set '${path}': it's a directory`);
      }
      if (existing instanceof File) existing.data = bytes;
      else parent.entries[leaf] = new File(bytes);
      return this;
    },
    get(path) {
      const node = lookupNode(root, path);
      return node instanceof File ? node.data : undefined;
    },
    has(path) {
      return lookupNode(root, path) instanceof File;
    },
    delete(path) {
      const r = lookupFull(root, path);
      if (!r || !(r.node instanceof File) || !r.parent) return false;
      delete r.parent.entries[r.name];
      return true;
    },
    *entries() { yield* walkFiles("", root); },
    *keys()    { for (const [p] of this.entries()) yield p; },
    *values()  { for (const [, v] of this.entries()) yield v; },
    [Symbol.iterator]() { return this.entries(); },
    get size() { let n = 0; for (const _ of this.entries()) n++; return n; },
    clear() { root.entries = {}; },
    populate(dir) {
      if (!(dir instanceof Directory)) throw new TypeError("fs.populate expects a Directory");
      root.entries = dir.entries;
    },
    get root() { return root; },
  };
}

// --- IO helpers (module-level, state-injected) ----------------------------
// Each helper takes an `io` state object containing exactly the mutable
// references it touches. Hoisting these out of the factory mirrors the
// "tree walker" treatment for read/write code paths and lets unit tests
// drive them with synthetic state ({ fs: mockFs, ... }) without
// instantiating wasm.

// fd_write helper: write iovec contents into the in-memory file backing
// `f`. Grows `io.fs` entry if needed; advances f.pos for non-append fds.
function writeToOpenFile({ fs }, f, view, memory, iovsPtr, iovsLen) {
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

// fd_read helper: drain bytes from the JS-side stdin buffer into iovec
// slots. Returns 0 (EOF) when buffer is empty.
function readFromStdin({ stdin }, view, memory, iovsPtr, iovsLen) {
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

// fd_read helper: drain bytes from an open file's backing array into
// iovec slots. Advances f.pos. Returns -1 if the path was removed under
// us (caller maps to E_BADF).
function readFromOpenFile({ fs }, f, view, memory, iovsPtr, iovsLen) {
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
function writeToStdio({ stdoutBuffer }, view, memory, iovsPtr, iovsLen) {
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

// --- Stdin helper (module-level) ------------------------------------------

function makeStdin(initial) {
  let bytes;
  if (initial == null) bytes = new Uint8Array(0);
  else if (typeof initial === "string") bytes = encoder.encode(initial);
  else if (initial instanceof Uint8Array) bytes = initial;
  else throw new TypeError("stdin must be a string, Uint8Array, or undefined");
  return {
    bytes,
    pushText(text) {
      const add = encoder.encode(text);
      const merged = new Uint8Array(this.bytes.length + add.length);
      merged.set(this.bytes);
      merged.set(add, this.bytes.length);
      this.bytes = merged;
    },
  };
}

// --- WASI factory ---------------------------------------------------------

/**
 * Build a fresh WASI preview1 implementation. Each call gets independent
 * state (env, args, stdin, fs, open-fd table, stdout buffering).
 *
 * @returns {{
 *   imports: object,
 *   bindInstance: (inst: WebAssembly.Instance) => void,
 *   env: Record<string, string>,
 *   args: string[],
 *   stdin: { bytes: Uint8Array, pushText: (s: string) => void },
 *   fs: object,
 * }}
 */
export function createWasiPreview1(options = {}) {
  const env = { ...(options.env ?? {}) };
  const args = [...(options.args ?? ["mruby-wasm-js"])];
  const stdin = makeStdin(options.stdin);
  const root = options.fs instanceof Directory ? options.fs : new Directory();
  const fs = createFsFacade(root);

  let nextFileFd = 4;
  // fd → { type: 'file', path, pos, append } | { type: 'dir', node }
  const openFiles = new Map();
  const stdoutBuffer = [];
  let instance = null;

  const { readUtf8 } = createMemoryHelpers(() => instance);

  // Single state bag passed to module-level IO helpers below. One
  // allocation up-front instead of per-call object literals.
  const io = { fs, stdin, stdoutBuffer };

  // --- WASI imports ------------------------------------------------------
  const imports = {
    fd_write(fd, iovsPtr, iovsLen, nwrittenPtr) {
      const view = new DataView(instance.exports.memory.buffer);
      const memory = new Uint8Array(instance.exports.memory.buffer);
      const f = openFiles.get(fd);
      if (f && f.type === "dir") return E_ISDIR;
      const total = f
        ? writeToOpenFile(io, f, view, memory, iovsPtr, iovsLen)
        : writeToStdio(io, view, memory, iovsPtr, iovsLen);
      view.setUint32(nwrittenPtr, total, true);
      return 0;
    },
    fd_close(fd) {
      if (openFiles.has(fd)) openFiles.delete(fd);
      return 0;
    },
    fd_seek(fd, offset, whence, newOffsetPtr) {
      const f = openFiles.get(fd);
      if (!f || f.type !== "file") return E_BADF;
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
      if (fd !== PREOPEN_FD) return E_BADF;
      const view = new DataView(instance.exports.memory.buffer);
      const nameBytes = encoder.encode(PREOPEN_PATH);
      view.setUint8(ptr, 0);
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
        total = readFromStdin(io, view, memory, iovsPtr, iovsLen);
      } else {
        const f = openFiles.get(fd);
        if (!f || f.type !== "file") return E_BADF;
        total = readFromOpenFile(io, f, view, memory, iovsPtr, iovsLen);
        if (total < 0) return E_BADF;
      }
      view.setUint32(nreadPtr, total, true);
      return 0;
    },
    fd_readdir(fd, bufPtr, bufLen, cookie, bufusedPtr) {
      const f = openFiles.get(fd);
      if (!f || f.type !== "dir") return E_BADF;
      const view = new DataView(instance.exports.memory.buffer);
      const memory = new Uint8Array(instance.exports.memory.buffer);
      const realNames = Object.keys(f.node.entries);
      const all = [".", "..", ...realNames];
      let bufPos = 0;
      for (let i = Number(cookie); i < all.length; i++) {
        const name = all[i];
        const nameBytes = encoder.encode(name);
        const recordSize = 24 + nameBytes.length;
        if (bufPos + recordSize > bufLen) break;
        for (let j = 0; j < 24; j++) view.setUint8(bufPtr + bufPos + j, 0);
        view.setBigUint64(bufPtr + bufPos, BigInt(i + 1), true);
        view.setBigUint64(bufPtr + bufPos + 8, BigInt(i + 1), true);
        view.setUint32(bufPtr + bufPos + 16, nameBytes.length, true);
        const child = i < 2 ? f.node : f.node.entries[name];
        view.setUint8(bufPtr + bufPos + 20,
          child instanceof Directory ? FILETYPE_DIRECTORY : FILETYPE_REGULAR_FILE);
        memory.set(nameBytes, bufPtr + bufPos + 24);
        bufPos += recordSize;
      }
      view.setUint32(bufusedPtr, bufPos, true);
      return 0;
    },
    path_open(dirfd, _dirflags, pathPtr, pathLen,
              oflags, _rightsBase, _rightsInh, fdflags, fdPtr) {
      if (debug.trace) console.log(`[wasi] path_open dirfd=${dirfd} path="${readUtf8(pathPtr, pathLen)}" oflags=${oflags} fdflags=${fdflags}`);
      if (dirfd !== PREOPEN_FD) return E_BADF;
      const fullPath = resolvePathToAbs(readUtf8(pathPtr, pathLen));
      const directory = !!(oflags & O_DIRECTORY);
      const create = !!(oflags & O_CREAT);
      const excl   = !!(oflags & O_EXCL);
      const trunc  = !!(oflags & O_TRUNC);
      const append = !!(fdflags & FD_APPEND);
      const node = lookupNode(root, fullPath);

      if (directory) {
        if (!node) return E_NOENT;
        if (!(node instanceof Directory)) return E_NOTDIR;
        const fd = nextFileFd++;
        openFiles.set(fd, { type: "dir", node });
        const view = new DataView(instance.exports.memory.buffer);
        view.setUint32(fdPtr, fd, true);
        return 0;
      }

      if (node instanceof Directory) return E_ISDIR;
      const exists = node instanceof File;
      if (excl && exists) return E_EXIST;
      if (!exists && !create) return E_NOENT;
      if (!exists || trunc) fs.set(fullPath, new Uint8Array(0));

      const data = fs.get(fullPath);
      const fd = nextFileFd++;
      openFiles.set(fd, { type: "file", path: fullPath, pos: append ? data.length : 0, append });
      const view = new DataView(instance.exports.memory.buffer);
      view.setUint32(fdPtr, fd, true);
      return 0;
    },
    path_filestat_get(dirfd, _flags, pathPtr, pathLen, ptr) {
      let baseDir;
      if (dirfd === PREOPEN_FD) {
        baseDir = root;
      } else {
        const f = openFiles.get(dirfd);
        if (!f || f.type !== "dir") return E_BADF;
        baseDir = f.node;
      }
      const node = resolveRelative(baseDir, readUtf8(pathPtr, pathLen));
      if (!node) return E_NOENT;
      const view = new DataView(instance.exports.memory.buffer);
      if (node instanceof Directory) writeFilestat(view, ptr, FILETYPE_DIRECTORY, 0);
      else writeFilestat(view, ptr, FILETYPE_REGULAR_FILE, node.data.length);
      return 0;
    },
    proc_exit(code) {
      console.log("[mruby] proc_exit", code);
    },
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
    clock_time_get(id, _precision, ptr) {
      const view = new DataView(instance.exports.memory.buffer);
      let nanos;
      if (id === 0) nanos = BigInt(Math.floor(Date.now() * 1e6));
      else {
        const now = (typeof performance !== "undefined" ? performance.now() : Date.now());
        nanos = BigInt(Math.floor(now * 1e6));
      }
      view.setBigUint64(ptr, nanos, true);
      return 0;
    },
    clock_res_get(_id, ptr) {
      const view = new DataView(instance.exports.memory.buffer);
      view.setBigUint64(ptr, 1_000_000n, true);
      return 0;
    },
    random_get(ptr, len) {
      const memory = new Uint8Array(instance.exports.memory.buffer, ptr, len);
      for (let off = 0; off < len; off += 65536) {
        const slice = memory.subarray(off, Math.min(off + 65536, len));
        crypto.getRandomValues(slice);
      }
      return 0;
    },
    fd_filestat_set_size(fd, size) {
      const f = openFiles.get(fd);
      if (!f || f.type !== "file") return E_BADF;
      const data = fs.get(f.path);
      if (!data) return E_BADF;
      const newSize = Number(size);
      if (newSize < 0) return E_INVAL;
      if (newSize < data.length) fs.set(f.path, data.slice(0, newSize));
      else if (newSize > data.length) {
        const grown = new Uint8Array(newSize);
        grown.set(data);
        fs.set(f.path, grown);
      }
      return 0;
    },
    fd_pwrite(fd, iovsPtr, iovsLen, offset, nwrittenPtr) {
      const f = openFiles.get(fd);
      if (!f || f.type !== "file") return E_BADF;
      const view = new DataView(instance.exports.memory.buffer);
      const memory = new Uint8Array(instance.exports.memory.buffer);
      const pseudo = { path: f.path, pos: Number(offset), append: false };
      const total = writeToOpenFile(io, pseudo, view, memory, iovsPtr, iovsLen);
      view.setUint32(nwrittenPtr, total, true);
      return 0;
    },
    path_unlink_file(dirfd, pathPtr, pathLen) {
      if (dirfd !== PREOPEN_FD) return E_BADF;
      const fullPath = resolvePathToAbs(readUtf8(pathPtr, pathLen));
      const node = lookupNode(root, fullPath);
      if (!node) return E_NOENT;
      if (node instanceof Directory) return E_ISDIR;
      fs.delete(fullPath);
      return 0;
    },
    path_create_directory(dirfd, pathPtr, pathLen) {
      if (dirfd !== PREOPEN_FD) return E_BADF;
      const fullPath = resolvePathToAbs(readUtf8(pathPtr, pathLen));
      const segs = pathSegments(fullPath);
      if (segs.length === 0) return E_EXIST;
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
      const fullPath = resolvePathToAbs(readUtf8(pathPtr, pathLen));
      const r = lookupFull(root, fullPath);
      if (!r || r.node == null) return E_NOENT;
      if (!(r.node instanceof Directory)) return E_NOTDIR;
      if (!r.parent) return E_INVAL;
      if (Object.keys(r.node.entries).length > 0) return E_NOTEMPTY;
      delete r.parent.entries[r.name];
      return 0;
    },
    fd_filestat_set_times(_fd, _atim, _mtim, _flags) { return E_INVAL; },
    fd_pread(_fd, _iovs, _iovsLen, _offset, _nreadPtr) { return E_INVAL; },
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
      const oldPath = resolvePathToAbs(readUtf8(oldPathPtr, oldPathLen));
      const newPath = resolvePathToAbs(readUtf8(newPathPtr, newPathLen));
      if (!fs.has(oldPath)) return E_NOENT;
      fs.set(newPath, fs.get(oldPath));
      fs.delete(oldPath);
      return 0;
    },
    path_symlink() { return E_INVAL; },
    poll_oneoff() { return E_INVAL; },
    sched_yield() { return 0; },
  };

  return {
    imports,
    bindInstance(inst) { instance = inst; },
    env,
    args,
    stdin,
    fs,
  };
}
