// Type smoke test for index.d.ts. Run with:
//   npx -p typescript@5 tsc --noEmit --module nodenext --moduleResolution nodenext --target es2022 --strict _smoke.ts
//
// Not shipped — exercises every exported shape so a future drift in
// index.d.ts surfaces as a tsc error.

import {
  createVM,
  Directory,
  File,
  createFsFacade,
  debug,
  RubyError,
  type FsFacade,
  type VMCore,
  type VMWithBundledWasi,
  type CreateVMOptions,
  type EvalOptions,
  type LoadBytecodeOptions,
} from "./index.js";

// --- Directory / File ---------------------------------------------------
const f: File = new File(new Uint8Array([1, 2, 3]));
const bytes: Uint8Array = f.data;
void bytes;

const root: Directory = new Directory({
  "hello.txt": new File(new TextEncoder().encode("hi")),
  nested: new Directory({ "a.txt": new File() }),
});
const childEntries: Record<string, File | Directory> = root.entries;
void childEntries;

// --- createFsFacade -----------------------------------------------------
const fs: FsFacade = createFsFacade(root);
fs.set("/x.txt", new Uint8Array(0)).set("/y.txt", new Uint8Array(0));
const got: Uint8Array | undefined = fs.get("/x.txt");
const present: boolean = fs.has("/x.txt");
const sz: number = fs.size;
void got; void present; void sz;
for (const [path, data] of fs) {
  const p: string = path;
  const d: Uint8Array = data;
  void p; void d;
}
const k: IterableIterator<string> = fs.keys();
void k.next();

// --- debug --------------------------------------------------------------
debug.trace = true;

// --- createVM with bundled WASI -----------------------------------------
const vmBundled: VMWithBundledWasi = await createVM({
  wasm: "/path/to/mruby-js.wasm",
  env: { LANG: "C.UTF-8" },
  args: ["mruby-wasm-js", "demo"],
  stdin: "hello\n",
  fs: root,
});
const rc: number = vmBundled.eval('puts "hi"');
void rc;
vmBundled.loadBytecode(new Uint8Array(0));
vmBundled.loadBytecode(new ArrayBuffer(0));
vmBundled.fs.set("/runtime-added.txt", new Uint8Array(0));
vmBundled.env.NEW_VAR = "1";
vmBundled.args.push("more");
vmBundled.stdin.pushText("more\n");

// --- createVM with custom WASI ------------------------------------------
const wasi: WebAssembly.ModuleImports = {
  fd_write: (() => 0) as unknown as Function,
};
const vmCustom: VMCore = await createVM({
  wasm: "/path/to/mruby-js.wasm",
  wasi,
  onStart: (inst) => {
    const start = inst.exports._start as () => void;
    start();
  },
});

// @ts-expect-error -- VMCore must NOT carry `fs` (that's bundled-only)
vmCustom.fs;

// --- CreateVMOptions union exposed for callers --------------------------
const opts: CreateVMOptions = { wasm: "x" };
void opts;

// --- VMCore handle table -----------------------------------------------
const h: number = vmCustom.alloc({ any: "value" });
const back: unknown = vmCustom.get(h);
vmCustom.release(h);
const live: number = vmCustom.handleCount();
void back; void live;

// --- evalScript ---------------------------------------------------------
vmBundled.evalScript("#ruby");
vmBundled.evalScript("#ruby", { filename: "embedded.rb", lineOffset: 5 });

// --- RubyError + eval options -------------------------------------------
const evalOpts: EvalOptions = { filename: "app.rb", lineOffset: 1, throw: false };
const loadOpts: LoadBytecodeOptions = { throw: false };
const noThrowRc: number = vmBundled.eval("nope", evalOpts);
const noThrowLoad: number = vmBundled.loadBytecode(new Uint8Array(0), loadOpts);
void noThrowRc; void noThrowLoad;

try {
  vmBundled.eval("def foo", { filename: "x.rb" });
} catch (e) {
  if (e instanceof RubyError) {
    const cls: string = e.rubyClass;
    const bt: string[] = e.backtrace;
    void cls; void bt;
  }
}
const re: RubyError = new RubyError({ class: "Boom", message: "x", backtrace: [] });
void re;
