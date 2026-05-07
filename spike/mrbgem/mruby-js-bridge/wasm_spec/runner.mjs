// Test runner for mruby-js-bridge. Boots the wasm in a Node-side
// browser-ish env, loads spec_helper.rb + each test_*.rb via evalRuby,
// then runs Spec.summary which sets JSBridge.global[:__test_failed__].
//
// Exit code 0 if all tests pass, 1 otherwise.
// Run with: `node mrbgem/mruby-js-bridge/wasm_spec/runner.mjs`
//
// The wasm path defaults to spike's build output (../../../host/mruby.wasm)
// but can be overridden via MRUBY_JS_BRIDGE_WASM env var so this gem's
// tests can run against any consumer's mruby.wasm:
//   MRUBY_JS_BRIDGE_WASM=/abs/path/to/mruby.wasm node wasm_spec/runner.mjs

import { readFile, readdir } from "node:fs/promises";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, join, resolve } from "node:path";
import { boot, evalRuby } from "../js/adapter.js";

// --- Browser-ish env shim --------------------------------------------------
// Tests use Date / Map / Set / Error / Promise / EventTarget / setTimeout —
// all Node 18+ provides those globally. We only need to make instantiateStreaming
// work from a local file path.

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
await boot(wasmUrl);

// --- Load spec_helper + all test_*.rb -------------------------------------
const testDir = here;
const allFiles = (await readdir(testDir)).sort();
const helper = "spec_helper.rb";
const testFiles = allFiles.filter((f) => f.startsWith("test_") && f.endsWith(".rb"));

console.log(`[runner] loading ${helper}`);
evalRuby(await readFile(join(testDir, helper), "utf8"));

for (const f of testFiles) {
  const src = await readFile(join(testDir, f), "utf8");
  console.log(`[runner] running ${f}`);
  const rc = evalRuby(src);
  if (rc !== 0) {
    console.error(`[runner] ${f} failed to load (parse/runtime error)`);
    process.exit(1);
  }
}

// Wait so any pending Promises (await tests, real-async setTimeout
// inside tests) have time to settle before we print the summary.
await new Promise((r) => setTimeout(r, 500));

evalRuby("Spec.summary");

// __test_failed__ was set by Spec.summary on globalThis via JS interop.
const failed = !!globalThis.__test_failed__;
process.exit(failed ? 1 : 0);
