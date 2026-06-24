// Type definitions for @takahashim/mruby-wasm-js
// mruby ↔ JavaScript bridge for WebAssembly.

/** A regular-file node in the virtual filesystem. */
export class File {
  constructor(data?: Uint8Array);
  data: Uint8Array;
}

/** A directory node in the virtual filesystem. */
export class Directory {
  constructor(entries?: Record<string, File | Directory>);
  entries: Record<string, File | Directory>;
}

/**
 * Map-style facade over a {@link Directory} tree. Iteration walks the
 * tree depth-first and yields only File leaves, keyed by absolute path.
 */
export interface FsFacade {
  set(path: string, bytes: Uint8Array): this;
  get(path: string): Uint8Array | undefined;
  has(path: string): boolean;
  delete(path: string): boolean;
  entries(): IterableIterator<[string, Uint8Array]>;
  keys(): IterableIterator<string>;
  values(): IterableIterator<Uint8Array>;
  [Symbol.iterator](): IterableIterator<[string, Uint8Array]>;
  readonly size: number;
  clear(): void;
  /** Replace root contents with another Directory's entries. */
  populate(dir: Directory): void;
  readonly root: Directory;
}

/** Wrap a {@link Directory} root as a Map-compatible facade. */
export function createFsFacade(root: Directory): FsFacade;

/** Mutable bundled-stdin handle exposed on the VM. */
export interface VMStdin {
  bytes: Uint8Array;
  pushText(s: string): void;
}

/**
 * Thrown by {@link VMCore.eval} / {@link VMCore.loadBytecode} when
 * mruby raises an unhandled exception. `rubyClass` mirrors
 * `exception.class.name`; `backtrace` mirrors `exception.backtrace`.
 */
export class RubyError extends Error {
  constructor(info?: { class?: string; message?: string; backtrace?: string[] });
  rubyClass: string;
  backtrace: string[];
}

/** Optional knobs for {@link VMCore.eval}. */
export interface EvalOptions {
  /** Filename surfaced in error backtraces (e.g., `"app.rb"`). */
  filename?: string;
  /**
   * 1-based line number that source line 1 reports as. Useful when the
   * Ruby was extracted from a wrapping context (e.g., `<script>` block
   * embedded at line 17 of an HTML file).
   */
  lineOffset?: number;
  /**
   * When `true` (default), mruby exceptions surface as a thrown
   * {@link RubyError}. Pass `false` to retain the legacy contract where
   * `eval` returns `1` on failure and the caller inspects rc.
   */
  throw?: boolean;
}

/** Optional knobs for {@link VMCore.loadBytecode}. */
export interface LoadBytecodeOptions {
  /** Same semantics as {@link EvalOptions.throw}. */
  throw?: boolean;
}

/** Methods common to every VM returned by {@link createVM}. */
export interface VMCore {
  instance: WebAssembly.Instance;

  /**
   * Parse + run Ruby source on the live VM. By default throws
   * {@link RubyError} on parse/runtime error. Returns 0 on success.
   * Throws `NotImplementedError` in compiler-less builds (use
   * {@link loadBytecode} instead). With `options.throw === false`,
   * returns 1 on error instead of throwing.
   */
  eval(source: string, options?: EvalOptions): number;

  /**
   * Load pre-compiled mruby bytecode (mrbc output). By default throws
   * {@link RubyError} on runtime error. Returns 0 on success. Accepts
   * `Uint8Array` or `ArrayBuffer`. Available in every build variant.
   * With `options.throw === false`, returns 1 on error instead of throwing.
   */
  loadBytecode(bytes: Uint8Array | ArrayBuffer, options?: LoadBytecodeOptions): number;

  /**
   * Eval the textContent of a DOM element matched by `selector`. Pairs
   * with `<script type="text/ruby">` blocks. Browser-only — throws if
   * `document` is undefined.
   */
  evalScript(selector: string, options?: EvalOptions): number;

  /** Power-user handle table — allocate a slot for a JS value. */
  alloc(value: unknown): number;
  /** Look up the JS value behind a handle. */
  get(handle: number): unknown;
  /** Release a handle slot. */
  release(handle: number): void;
  /** Live handle count (useful for leak detection in tests). */
  handleCount(): number;
}

/**
 * VM returned when `createVM` is invoked without `options.wasi`.
 * The bundled WASI preview1 impl owns fs / env / args / stdin and
 * exposes them here.
 */
export interface VMWithBundledWasi extends VMCore {
  fs: FsFacade;
  env: Record<string, string>;
  args: string[];
  stdin: VMStdin;
}

/** Options shared by every {@link createVM} call. */
interface CreateVMOptionsBase {
  /** URL to mruby-js.wasm. Required. */
  wasm: string;
  /**
   * Post-instantiate callback. Defaults to calling
   * `instance.exports._initialize()` for reactor modules, falling back
   * to `_start()` for command modules.
   */
  onStart?: (instance: WebAssembly.Instance) => void;
}

/**
 * Options when using the bundled in-memory WASI preview1 impl
 * (default — when `wasi` is omitted).
 */
export interface CreateVMOptionsBundled extends CreateVMOptionsBase {
  wasi?: undefined;
  /** Initial ENV available to Ruby via `ENV[]`. */
  env?: Record<string, string>;
  /** Initial ARGV. `args[1..]` lands in Ruby's `ARGV`. */
  args?: string[];
  /** Initial stdin payload for `STDIN.read` / `gets`. */
  stdin?: string | Uint8Array;
  /** Initial root directory for the virtual filesystem. */
  fs?: Directory;
}

/**
 * Options when supplying a replacement `wasi_snapshot_preview1` import
 * object (e.g. `@bjorn3/browser_wasi_shim`). The returned VM does NOT
 * include fs / env / args / stdin — the caller's WASI owns that state.
 */
export interface CreateVMOptionsCustomWasi extends CreateVMOptionsBase {
  wasi: WebAssembly.ModuleImports;
}

export type CreateVMOptions = CreateVMOptionsBundled | CreateVMOptionsCustomWasi;

/**
 * Instantiate a fresh mruby VM. Each call gets an independent handle
 * table + WASI state — multiple VMs can coexist in one process.
 */
export function createVM(options: CreateVMOptionsCustomWasi): Promise<VMCore>;
export function createVM(options: CreateVMOptionsBundled): Promise<VMWithBundledWasi>;

/** Global debug toggle (`{ trace: false }` by default). */
export const debug: { trace: boolean };
