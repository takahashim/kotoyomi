# spike: mruby bridge for kotoyomi

`js` gem に依存しない自前 mrbgem で kotoyomi を mruby + WebAssembly 上で動かす実験。
Phase 1 で `JSBridge.eval` の最小プロトタイプ、Phase 2a–2c で primitive 一式と
BasicObject ベースの Ruby ラッパー、Phase 2d で `lib/*.rb` を移植してブラウザ上で
sample player を動作させるところまで到達。

詳しい経緯は `docs/phase1-spike-summary.md` と `docs/phase2-spike-summary.md`、
全体ロードマップは `docs/mruby-bridge.md` 参照。

## Prerequisites

- macOS arm64 (current host) — その他のプラットフォームでは Makefile 内の
  `WASI_SDK_URL` を差し替え
- Ruby + rake (mruby のビルドが使用)
- Node 18+ (smoke test 実行に使用、ブラウザ確認のみなら不要)

## Layout

```
spike/
├── Makefile                # build orchestration
├── README.md
├── .gitignore              # mruby/, vendor/, host/mruby-js.wasm を除外
├── build_config/
│   ├── wasi-js.rb          # JS-host build (mruby + mruby-wasm-js + WASI mgems)
│   └── wasi-cmd.rb         # command build (mruby + mruby-bin-mruby + WASI mgems, no JS bridge)
├── mruby/                  # gitignored、`make mruby` で git clone される
├── mrbgem/
│   └── mruby-wasm-js/    # ── 再配布可能な gem 本体 (詳細は gem の README) ──
│       ├── mrbgem.rake
│       ├── README.md             # gem 単体の使い方
│       ├── src/js_bridge.c       # C primitive (WASM imports + Value)
│       ├── mrblib/js_bridge.rb   # BasicObject ベースの Ruby ラッパー
│       ├── js/index.js          # JS 側 host (createVM factory + JSBridge core)
│       └── wasm_spec/            # gem 自前のテスト (test/ ではない: mruby-test 衝突回避)
│           ├── spec_helper.rb
│           ├── runner.mjs
│           └── test_*.rb
├── main/main.c             # mrb_open() のみ、JS が evalRuby で driving
├── app/                    # lib/*.rb の mruby ポート版 (Phase 2d)
│   ├── dom.rb
│   ├── renderer.rb
│   ├── player.rb
│   └── kotoyomi.rb
├── vendor/                 # gitignored、wasi-sdk download/extract
└── host/                   # ── spike (gem を使う consumer) のデモアセット ──
    ├── boot-kotoyomi.js          # kotoyomi sample 用 boot (.rb fetch + evalRuby)
    ├── index.html                # spike のランディング
    ├── phase2c.html              # Phase 2c 機能の boot-only smoke
    ├── sample/
    │   ├── index.html            # kotoyomi player (works/sample と同等)
    │   ├── poems/sample.{mp3,vtt}
    │   └── ...
    ├── app.css                   # ルートの app.css のコピー
    ├── run-node.mjs              # Phase 2c 機能の Node smoke
    ├── run-kotoyomi-node.mjs     # kotoyomi 起動シナリオの Node smoke
    ├── mruby-js.wasm             # gitignored、JS-host build 成果
```

`index.js` は **gem 内部** (`mrbgem/mruby-wasm-js/js/index.js`) に
あります。spike 側 (`host/*.js`、`host/*.html`) はそれを相対パスで
import する consumer です。

## Build

```bash
make download   # wasi-sdk-33 (~173MB) を vendor/ に取得 (resumable)
make all        # 展開 → mruby ビルド → main.c とリンク
make serve      # docroot は spike/、http://localhost:8001/host/sample/ へ
```

完全にやり直したい場合は `make distclean` で wasi-sdk + mruby/build を削除。

ダウンロードが途中で止まった場合は `make download` を再実行すれば
`curl --continue-at -` で続きから取得します。

## ブラウザでの確認

- http://localhost:8001/host/sample/ — kotoyomi player (再生でハイライト遷移、
  「最初に戻る」ボタン、エラー表示まで動く)
- http://localhost:8001/host/phase2c.html — Phase 2c 機能 (BasicObject、Float、
  Promise.then、addEventListener+once) の boot-only smoke
- http://localhost:8001/host/ — 上記へのリンク集

`debug.trace = true` を `mrbgem/mruby-wasm-js/js/index.js` で有効にすると、
handle release / callback 発火を console に出します (デフォルトは off)。

## gem 単体のテスト

```bash
make test                                # spike Makefile 経由 (link → wasm_spec/runner.mjs)
node mrbgem/mruby-wasm-js/wasm_spec/runner.mjs   # 直接実行
```

別プロジェクトの wasm を使いたい場合は env var で指定:

```bash
MRUBY_WASM_PATH=/abs/path/to/mruby-js.wasm \
  node mrbgem/mruby-wasm-js/wasm_spec/runner.mjs
```

## 配布用バンドル (Phase A)

`make dist` で `dist/mruby-wasm-js/` に publishable な形のバンドルを出力。

```bash
make dist
# → dist/mruby-wasm-js/
#     ├── package.json     (name, exports, files)
#     ├── index.js       (gem の js/index.js のコピー)
#     ├── mruby-js.wasm    (build 成果、JS-host)
#     ├── README.md
#     └── LICENSE
```

consumer 側での利用例:

```js
// 1. cp -r dist/mruby-wasm-js/ をベンダーに配置:
import { createVM } from "./vendor/mruby-wasm-js/index.js";
await boot(new URL("./vendor/mruby-wasm-js/mruby-js.wasm", import.meta.url).href);

// 2. npm publish 後 (Phase C):
import { createVM } from "mruby-wasm-js";
import wasmUrl from "mruby-wasm-js/wasm";
await boot(wasmUrl);
```

将来 GitHub Releases (Phase B) や npm publish (Phase C) を足す場合の
土台。今は version 固定 (`0.0.0-dev`) なので、リリース前に Makefile の
`DIST_VERSION` を bump する。

## Node での smoke

```bash
node host/run-node.mjs           # Phase 2c 機能の検証
node host/run-kotoyomi-node.mjs  # kotoyomi 起動 → fake cue 2 つで Renderer 動作確認
```

## 動作確認済みのスタック

- mruby HEAD (default-no-stdio から `mruby-regexp` 除外、`mruby-method` 追加)
- wasi-sdk 33.0 (clang 22 + WebAssembly EH ベースの SJLJ)
- Ruby BasicObject + method_missing で ruby.wasm 互換の interop API

## 次のステップ (Phase 2e)

`lib/*.rb` を `spike/app/*.rb` の内容で上書き、`src/ruby_runtime.js` を
`spike/host/boot-kotoyomi.js` ベースで書き直して、main 側 (kotoyomi 本体) を
mruby 駆動に切り替える。`docs/phase2-spike-summary.md` の §6 残課題を参照。
