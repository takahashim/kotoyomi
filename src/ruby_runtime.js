// kotoyomi のランタイム = mruby + @takahashim/mruby-wasm-js (npm)。
// ブラウザでは works/sample/index.html の importmap 経由で CDN URL に解決され、
// Node では package.json の依存として node_modules から解決される。
//
// 起動の流れ:
//   1. createVM({ wasm }) で mruby-js.wasm を instantiate
//   2. lib/*.rb を fetch して 1 ファイルずつ vm.eval に流す
//   3. vm.eval("Kotoyomi.start") で App を起動
//
// `vm.eval` は内部で source を Fiber でくるむので、Ruby 側の
// `value.await` がそのまま動く (例: lib/kotoyomi.rb の wait_for_track_load)。

import { createVM } from "@takahashim/mruby-wasm-js";

const RUBY_SOURCES = [
  "lib/dom.rb",
  "lib/renderer.rb",
  "lib/player.rb",
  "lib/kotoyomi.rb",
].map((path) => new URL(`../${path}`, import.meta.url).href);

// import.meta.resolve は importmap (browser) / package.json#exports (Node)
// 両方を統一インタフェースで解決する。
const WASM_URL = import.meta.resolve("@takahashim/mruby-wasm-js/wasm");

export async function bootRuby() {
  const vm = await createVM({ wasm: WASM_URL });

  const sources = await Promise.all(
    RUBY_SOURCES.map(async (path) => {
      const res = await fetch(path);
      if (!res.ok) throw new Error(`${path} の取得に失敗しました (${res.status})`);
      return res.text();
    }),
  );

  for (const source of sources) {
    const rc = vm.eval(source);
    if (rc !== 0) throw new Error("Ruby ソースのロードに失敗しました (詳細はコンソール)");
  }

  vm.eval("Kotoyomi.start");
  return vm;
}
