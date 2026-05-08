// Test runner for mruby-js-bridge. Builds a fresh VM, loads
// spec_helper.rb + each test_*.rb via vm.eval, then runs Spec.summary
// which sets JSBridge.global[:__test_failed__].
//
// Exit code 0 if all tests pass, 1 otherwise.
// Run with: `node mrbgem/mruby-js-bridge/wasm_spec/runner.mjs`
//
// The wasm path defaults to spike's build output (../../../host/mruby.wasm)
// but can be overridden via MRUBY_JS_BRIDGE_WASM env var.

import { readFile, readdir } from "node:fs/promises";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, join, resolve } from "node:path";
import { createVM, Directory, File, debug } from "../js/adapter.js";

if (process.env.MRUBY_JS_BRIDGE_TRACE) debug.trace = true;

// --- Browser-ish env shim -------------------------------------------------
const here = dirname(fileURLToPath(import.meta.url));
globalThis.fetch = async (url) => {
  const path = fileURLToPath(new URL(url, import.meta.url));
  return new Response(await readFile(path), {
    headers: { "Content-Type": url.endsWith(".wasm") ? "application/wasm" : "text/plain" },
  });
};

const wasmUrl = process.env.MRUBY_JS_BRIDGE_WASM
  ? pathToFileURL(resolve(process.cwd(), process.env.MRUBY_JS_BRIDGE_WASM)).href
  : new URL("../../../host/mruby.wasm", import.meta.url).href;

// Build the initial tree fixture declaratively. Includes flat fixtures
// (spec_fixture.txt / spec_binary.dat) at root plus nested directories
// (data/, empty_dir/, auto/created/) that the Dir + tree specs exercise.
const initialFs = new Directory({
  "spec_fixture.txt": new File(new TextEncoder().encode("spec\nfixture\nlines\n")),
  "spec_binary.dat": new File(new Uint8Array([0xDE, 0xAD, 0xBE, 0xEF])),
  data: new Directory({
    "poem.vtt": new File(new TextEncoder().encode("WEBVTT\n\nfixture\n")),
  }),
  empty_dir: new Directory(),
});

const vm = await createVM({
  wasm: wasmUrl,
  env: { SPEC_RUNNER: "wasm_spec" },
  args: ["mruby-js-bridge", "--smoke", "test_wasi", "fixture"],
  stdin: "stdin payload\n",
  fs: initialFs,
});

// Add a path via the Map facade post-create to also exercise auto-create
// of intermediate directories at runtime.
vm.fs.set("/auto/created/leaf.txt", new TextEncoder().encode("auto\ncreated\n"));

// Sanity-check the tree shape from JS (these features have no Ruby
// surface in mruby core, so the asserts live here).
function assert(cond, msg) {
  if (!cond) {
    console.error("[runner] tree assert failed:", msg);
    process.exit(1);
  }
}
assert(vm.fs.root.entries.data instanceof Directory, "data is a Directory");
assert(vm.fs.root.entries.data.entries["poem.vtt"] instanceof File, "data/poem.vtt is a File");
assert(vm.fs.root.entries.empty_dir instanceof Directory, "empty_dir is a Directory");
assert(Object.keys(vm.fs.root.entries.empty_dir.entries).length === 0, "empty_dir is empty");
assert(vm.fs.root.entries.auto instanceof Directory, "fs.set auto-created /auto");
assert(vm.fs.has("/data/poem.vtt"), "fs.has on nested path");
assert(!vm.fs.has("/data"), "fs.has returns false for directories");

// --- Load spec_helper + all test_*.rb -------------------------------------
const testDir = here;
const allFiles = (await readdir(testDir)).sort();
const helper = "spec_helper.rb";
const testFiles = allFiles.filter((f) => f.startsWith("test_") && f.endsWith(".rb"));

console.log(`[runner] loading ${helper}`);
vm.eval(await readFile(join(testDir, helper), "utf8"));

for (const f of testFiles) {
  const src = await readFile(join(testDir, f), "utf8");
  console.log(`[runner] running ${f}`);
  const rc = vm.eval(src);
  if (rc !== 0) {
    console.error(`[runner] ${f} failed to load (parse/runtime error)`);
    process.exit(1);
  }
}

// Wait so any pending Promises (await tests, real-async setTimeout
// inside tests) have time to settle before we print the summary.
await new Promise((r) => setTimeout(r, 500));

vm.eval("Spec.summary");

// __test_failed__ was set by Spec.summary on globalThis via JS interop.
const failed = !!globalThis.__test_failed__;
process.exit(failed ? 1 : 0);
