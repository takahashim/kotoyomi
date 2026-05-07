// Boots the mruby VM and loads the kotoyomi app's Ruby files into it.
//
// Counterpart to src/ruby_runtime.js (which uses ruby.wasm + DefaultRubyVM).
// Difference: we have no DefaultRubyVM, so the boot path is:
//   1. boot(wasm) — instantiates the wasm + runs gem_init (via _start)
//   2. fetch each .rb in dependency order
//   3. evalRuby(source) for each one
//   4. evalRuby("Kotoyomi.start")
//
// The Ruby files themselves expect `JS = JSBridge` (the alias is set
// at the top of dom.rb so subsequent files don't need to re-set it).

import { boot, evalRuby } from "../mrbgem/mruby-js-bridge/js/adapter.js";

// Resolve relative to this file so the host page can live anywhere.
const APP_SOURCES = [
  "../../app/dom.rb",
  "../../app/renderer.rb",
  "../../app/player.rb",
  "../../app/kotoyomi.rb",
].map((path) => new URL(path, import.meta.url).href);

const WASM_URL = new URL("./mruby.wasm", import.meta.url).href;

async function bootKotoyomi() {
  await boot(WASM_URL);

  const sources = await Promise.all(
    APP_SOURCES.map(async (path) => {
      const res = await fetch(path);
      if (!res.ok) throw new Error(`${path} fetch failed (${res.status})`);
      return res.text();
    }),
  );

  for (const src of sources) {
    const rc = evalRuby(src);
    if (rc !== 0) throw new Error("ruby load failed (see console)");
  }
  evalRuby("Kotoyomi.start");
}

async function main() {
  try {
    await bootKotoyomi();
  } catch (err) {
    console.error(err);
    const errorEl = document.getElementById("error");
    if (errorEl) {
      errorEl.textContent = `起動に失敗しました。\n${
        err instanceof Error ? err.message : String(err)
      }`;
      errorEl.hidden = false;
    }
  }
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => main());
} else {
  main();
}
