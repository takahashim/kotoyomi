// kotoyomi スライドビューアのランタイム = Lilac (lilac.wasm) + ブリッジ
// mruby-wasm-js。Lilac v0.1.0 の成果物を ../vendor/lilac/ に同梱している
// (https://takahashim.github.io/lilac/v0.1.0/ と同一レイアウト・オフライン対応)。
//
// このファイルは「最小のブートシム」だけを担う:
//   1. createVM({ wasm }) で lilac.wasm を instantiate
//   2. lib/*.rb を fetch して 1 ファイルずつ vm.eval(コンポーネント定義 + register)
//   3. vm.eval("Lilac.start") で body を走査し data-component を mount
//
// slides.json の取得・パース等のアプリロジックは一切 JS では行わない
// (Ruby 側 deck#setup が Fetchy.json で取得し Kotoyomi::Slides.parse で取り込む)。

import { createVM } from "../vendor/lilac/index.js";

const RUBY_SOURCES = [
  "lib/bus.rb",
  "lib/slides.rb",
  "lib/renderer.rb",
  "lib/player.rb",
  "lib/vtt_track.rb",
  "lib/slide.rb",
  "lib/deck.rb",
].map((path) => new URL(`../${path}`, import.meta.url).href);

const WASM_URL = new URL("../vendor/lilac/lilac.wasm", import.meta.url).href;

export async function bootRuby() {
  const vm = await createVM({ wasm: WASM_URL });

  const sources = await Promise.all(
    RUBY_SOURCES.map(async (path) => {
      const res = await fetch(path);
      if (!res.ok) throw new Error(`${path} の取得に失敗しました (${res.status})`);
      return { path, source: await res.text() };
    }),
  );

  for (const { path, source } of sources) {
    vm.eval(source, { filename: path });
  }

  vm.eval("Lilac.start");
  return vm;
}
