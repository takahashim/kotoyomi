// kotoyomi スライドビューアのランタイム = Lilac (:full) + ブリッジ
// mruby-wasm-js。ランタイムは lilac-wasm-bin gem 由来の release 成果物を
// `make vendor-lilac` で ../vendor/lilac/ に同梱している(オフライン対応)。
// レイアウトは vendor/lilac/{lilac.wasm, mruby-wasm-js/} で、createVM は
// ブリッジ(mruby-wasm-js/index.js)から読む。
//
// このファイルは「最小のブートシム」だけを担う:
//   1. createVM({ wasm }) で lilac.wasm を instantiate
//   2. lib/*.rb を fetch して 1 ファイルずつ vm.eval(コンポーネント定義 + register)
//   3. vm.eval("Lilac.start") で body を走査し data-component を mount
//
// ロード方式(2)はここ一箇所に閉じている。将来 :compiled(軽量化)へ移る
// 場合の差し替え点はこの bootRuby():lilac-compiled.wasm を読み、fetch+eval
// の代わりに事前コンパイルした .mrb を vm.loadBytecode する形にすればよい。
//
// slides.json の取得・パース等のアプリロジックは一切 JS では行わない
// (Ruby 側 deck#setup が Fetchy.json で取得し Kotoyomi::Slides.parse で取り込む)。

import { createVM } from "../vendor/lilac/mruby-wasm-js/index.js";

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
