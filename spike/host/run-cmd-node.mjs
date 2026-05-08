// Smoke runner for the command / wasmtime variant of mruby (host/mruby-cmd.wasm).
//
// Drives the wasm via Node's built-in WASI (preview1). Used by the
// `make smoke-cmd` target; also handy for ad-hoc testing.
//
// We use Node's WASI because wasmtime ≥36 dropped support for the
// legacy exception bytecode that clang's SJLJ implementation emits.
// Node's WASI accepts this bytecode and is always available since the
// JS-host workflow already requires Node 18+.
//
// Usage:
//   node --experimental-wasi-unstable-preview1 host/run-cmd-node.mjs [path/to/script.rb]
// If no script path is given, runs the inline self-test below.

import { WASI } from "node:wasi";
import { readFile, writeFile, mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const wasmPath = fileURLToPath(new URL("./mruby-cmd.wasm", import.meta.url));

let scriptPath = process.argv[2];
let workDir;

if (!scriptPath) {
  // No script given — run inline self-test exercising Time / rand / ENV / File / Dir.
  workDir = await mkdtemp(join(tmpdir(), "mruby-cmd-smoke-"));
  scriptPath = join(workDir, "selftest.rb");
  await writeFile(scriptPath, `
puts "[smoke] hello from mruby-cmd.wasm via Node WASI"
puts "[smoke] Time.now    = #{Time.now}"
puts "[smoke] rand(1000)  = #{rand(1000)}"
puts "[smoke] ENV[SMOKE]  = #{ENV['SMOKE']}"
File.open("${workDir}/written.txt", "w") { |f| f.write("inside-wasm\\n") }
puts "[smoke] File.read   = #{File.read('${workDir}/written.txt').strip}"
entries = Dir.entries("${workDir}").sort
puts "[smoke] Dir.entries = #{entries.inspect}"
puts "[smoke] OK"
`);
}

const wasi = new WASI({
  version: "preview1",
  args: ["mruby", scriptPath],
  env: { ...process.env, SMOKE: "yes" },
  preopens: workDir ? { [workDir]: workDir } : { ".": "." },
});

const wasmBuffer = await readFile(wasmPath);
const wasm = await WebAssembly.compile(wasmBuffer);
const instance = await WebAssembly.instantiate(wasm, wasi.getImportObject());
wasi.start(instance);
