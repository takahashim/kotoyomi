// Phase 2c smoke test — exercises every bridge feature against a minimal
// browser-ish env. Boots mruby, then drives Ruby evaluation from the host
// via evalRuby (no embedded SCRIPT in main.c anymore).
//
// Usage: node host/run-node.mjs

import { readFile } from "node:fs/promises";
import { boot, evalRuby } from "./adapter.js";

globalThis.document = {
  _title: "",
  set title(v) { this._title = v; console.log("[doc] title =", v); },
  get title() { return this._title; },
  getElementById(id) {
    if (id === "does-not-exist") return null;
    return { id };
  },
};
globalThis.queueMicrotask = (fn) => Promise.resolve().then(fn);

const wasmBytes = await readFile(new URL("./mruby.wasm", import.meta.url));
globalThis.fetch = async () => new Response(wasmBytes, {
  headers: { "Content-Type": "application/wasm" },
});

await boot("./mruby.wasm");

const SCRIPT = `
puts 'BasicObject + await-replacement test'
JS = Kotoyomi::JS
doc = JS.global[:document]

doc.title = 'BasicObject OK'
puts "1. title = #{doc[:title].to_s}"

n = JS.eval('1.5 + 2.25')
puts "2. float = #{n.to_f}"

opts = JS.object(once: true)
puts "3. opts.once = #{opts[:once].to_s}"

missing = doc.getElementById('does-not-exist')
puts "4. nil? = #{missing.nil?}"

JS.global[:Promise].resolve(7).then { |v| puts "5. promise resolved: #{v.to_i}" }

target = JS.eval('new EventTarget()')
target.on(:ready, JS.object(once: true)) { |_ev| puts '6. ready event fired' }
evt = JS.eval("new Event('ready')")
target.dispatchEvent(evt)
target.dispatchEvent(evt)

puts 'sync part done'
`;

evalRuby(SCRIPT);

await new Promise((r) => setTimeout(r, 50));
console.log("--- node run done ---");
