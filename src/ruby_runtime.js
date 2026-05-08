// kotoyomi のランタイム = mruby + mruby-wasm-js (JS-host edition)。ruby.wasm
// + js gem の旧構成は ../vendor/mruby-wasm-js/ にバンドル化された自前
// パッケージに置換済み。
//
// 起動の流れ:
//   1. createVM({ wasm }) で mruby-js.wasm を instantiate (index.js の WASM
//      imports を満たすことで JSBridge.* / WASI fd_write 等が動くようになる)
//   2. lib/*.rb を fetch して 1 ファイルずつ vm.eval に流す
//   3. vm.eval("Kotoyomi.start") で App を起動
//
// `vm.eval` は内部で source を Fiber でくるむので、Ruby 側の
// `value.await` がそのまま動く (例: lib/kotoyomi.rb の wait_for_track_load)。

import { createVM } from "../vendor/mruby-wasm-js/index.js";

const RUBY_SOURCES = [
  "lib/dom.rb",
  "lib/renderer.rb",
  "lib/player.rb",
  "lib/kotoyomi.rb",
].map((path) => new URL(`../${path}`, import.meta.url).href);

const WASM_URL =
  new URL("../vendor/mruby-wasm-js/mruby-js.wasm", import.meta.url).href;

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
