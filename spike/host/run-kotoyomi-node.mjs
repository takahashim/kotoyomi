// Node smoke test for kotoyomi-on-mruby. Doesn't simulate the actual DOM
// or audio playback — only verifies that all four .rb files load without
// raising and that App#initialize → start dispatches without exceptions.
//
// We provide just enough DOM/EventTarget/Audio shimming for App#start to
// register listeners and bail out cleanly when the simulated <track>
// hasn't loaded yet.

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { createVM } from "../mrbgem/mruby-wasm-js/js/index.js";

// --- Minimal DOM/Audio/Event shims -----------------------------------------
class FakeNode {
  constructor(tag = "div") {
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.dataset = {};
    this.classList = {
      _set: new Set(),
      add(name) { this._set.add(name); },
      remove(name) { this._set.delete(name); },
    };
    this._listeners = new Map();
    this.hidden = false;
    this.id = "";
    this.className = "";
    this.textContent = "";
    this.innerHTML = "";
  }
  appendChild(child) {
    this.children.push(child);
    return child;
  }
  addEventListener(type, fn, _opts) {
    if (!this._listeners.has(type)) this._listeners.set(type, []);
    this._listeners.get(type).push(fn);
  }
}

const audio = Object.assign(new FakeNode("audio"), { currentTime: 0 });
const track = Object.assign(new FakeNode("track"), { readyState: 0 });
// Stand-in for HTMLTrackElement.track — the textTrack with cues.
const FAKE_CUES = [
  { id: "c1", startTime: 0, endTime: 1.5, text: "あさ\nゆきが\nふって" },
  { id: "",   startTime: 1.5, endTime: 3, text: "ひるに\nやんだ" },
];
const cuesArrayLike = { length: FAKE_CUES.length };
FAKE_CUES.forEach((c, i) => { cuesArrayLike[i] = c; });
track.track = {
  mode: "disabled",
  cues: cuesArrayLike,
  addEventListener: track.addEventListener.bind(track),
};
const poem = new FakeNode("div");
const errorEl = Object.assign(new FakeNode("p"), { hidden: true });
const resetBtn = new FakeNode("button");

const elements = {
  audio, track, poem, error: errorEl, reset: resetBtn,
};

globalThis.document = {
  getElementById(id) { return elements[id] ?? null; },
  createElement(tag) { return new FakeNode(tag); },
};
globalThis.console = console;
globalThis.queueMicrotask = (fn) => Promise.resolve().then(fn);

// fetch polyfill so adapter's instantiateStreaming works on a local path.
globalThis.fetch = async (url) => {
  const path = fileURLToPath(new URL(url, import.meta.url));
  const bytes = await readFile(path);
  return new Response(bytes, {
    headers: { "Content-Type": url.endsWith(".wasm") ? "application/wasm" : "text/plain" },
  });
};

// --- Boot + load app -------------------------------------------------------
const vm = await createVM({ wasm: new URL("./mruby-js.wasm", import.meta.url).href });

// Load the canonical kotoyomi lib from the repo root. Since Phase 2e
// migrated lib/ to mruby + JSBridge, the same files run here under Node
// against the gem (with a fake DOM/Audio shim above).
const APP = ["lib/dom.rb", "lib/renderer.rb", "lib/player.rb", "lib/kotoyomi.rb"];
for (const rel of APP) {
  const src = await readFile(new URL(`../../${rel}`, import.meta.url), "utf8");
  console.log(`[load] ${rel}`);
  const rc = vm.eval(src);
  if (rc !== 0) {
    console.error(`[load] ${rel} failed`);
    process.exit(1);
  }
}

console.log("[run] Kotoyomi.start");
vm.eval("Kotoyomi.start");

// --- Simulate the <track> finishing loading -------------------------------
// App#start should have registered load/error listeners. Fire 'load'.
await new Promise((r) => setTimeout(r, 10));
console.log("[sim] firing track 'load'");
track.readyState = 2;
const loadFns = track._listeners.get("load") ?? [];
for (const fn of loadFns) fn({ type: "load" });

await new Promise((r) => setTimeout(r, 50));
console.log("--- node kotoyomi run done ---");
console.log("poem.children:", poem.children.length);
