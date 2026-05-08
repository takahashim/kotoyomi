# Kotoyomi

縦書きで文章を表示し、朗読音声と同期して現在の段落テキストをハイライトするスタンドアローンなWebプレイヤー。

朗読データは [WebVTT](https://developer.mozilla.org/ja/docs/Web/API/WebVTT_API) に格納し、ブラウザ標準の `<track kind="metadata">` でロード・パース・同期する。プレイヤー制御と DOM 操作は **mruby** (WASM 化) 上の Ruby が担い、JS は mruby ランタイムの起動と最小限のホストだけを担当する。

ビルドステップは無く、ブラウザの ES Modules 機能で `src/*.js` がそのまま動く。Ruby ランタイムも `vendor/mruby-wasm-js/mruby-js.wasm` を self-host しているので CDN 依存ゼロ。

詳細仕様は [`spec.md`](./spec.md) を参照。当初は ruby.wasm + `js` gem ベースだったが、Phase 2 で自前 mrbgem (`mruby-wasm-js`) に切り替えた。trade-off は [`docs/runtime-tradeoffs.md`](./docs/runtime-tradeoffs.md) に整理してある。

## 役割分担

| 層                       | 役割                                                   |
| ------------------------ | ------------------------------------------------------ |
| WebVTT                   | 朗読データ                                             |
| ブラウザ (TextTrack API) | フォーマット解釈と音声同期                             |
| Ruby (mruby + mruby-wasm-js) | プレイヤー制御・状態遷移・DOM 操作               |
| CSS                      | 視覚効果                                               |
| JS                       | mruby-js.wasm の createVM + JSBridge imports 提供 (`index.js`) |

## 要件

- ローカル動作確認: Ruby + Bundler
- (CDN や外部ホスティングへのアクセスは不要 — ランタイム一式 self-host)

## ローカルでの動作確認

```bash
bundle install                # 初回のみ
bundle exec wsv
```

[wsv](https://github.com/takahashim/wsv) を使った静的配信です。`Gemfile` に定義してあり、設定ファイル不要、デフォルトで `127.0.0.1:8000` で起動します。

ブラウザで以下を開きます:

- `http://localhost:8000/works/sample/` — 動くデモ

mruby ランタイム (`vendor/mruby-wasm-js/mruby-js.wasm`、約 4MB / gzip 約 1MB) はリポジトリに同梱しているので、初回ロードも数百ミリ秒以内です。`<audio>` の再生ボタンで段落がフェードインしながらハイライトされ、「最初に戻る」ボタンで冒頭に戻ります。

## 使い方

このリポジトリはテンプレートとして使います。想定するユースケースは 2 つです。

### ユースケース 1: ローカルで実行する

自分の環境で朗読作品を実行したい、または公開せずに作品を編集・確認したい場合。

```bash
git clone https://github.com/takahashim/kotoyomi.git
cd kotoyomi
bundle install
bundle exec wsv
```

ブラウザで `http://localhost:8000/works/sample/` を開けばサンプルが動きます。自分の作品を加えるなら `works/<作品名>/` を新設して `works/sample/` を真似ます。

### ユースケース 2: 自分の Web サイトで公開する

朗読作品を Web で公開したい場合。GitHub のアカウントがあるなら fork が一番手軽です。

1. このリポジトリを **fork**
2. fork した自分のリポジトリで GH Pages を有効化 (Settings → Pages → Source: GitHub Actions)
3. `works/<作品名>/` を追加して push
4. `https://yourname.github.io/kotoyomi/works/<作品名>/` で公開される

GitHub 以外でホスティングしたい (Netlify、自分の VPS、S3 等) なら clone して必要なファイル一式 (root の `index.html` `app.css` `src/` `lib/` `works/` `vendor/`) を任意の静的ホスティングに置けば動きます。

## 作品を追加する

`works/sample/` を雛形にコピーして、自分の朗読音声 (`.mp3`) と WebVTT 字幕 (`.vtt`) に差し替えます。

```
works/
  takahashim/
    index.html      # works/sample/index.html をコピー、audio/track の src を差し替え
    poems/
      takahashim.mp3
      takahashim.vtt
```

`index.html` のツール参照 (`../../src/main.js`、`../../app.css`) は sample と同じものでそのまま動きます。

## 必要な DOM 規約

ツールは以下の DOM ID/class を期待しています:

- `#audio` — `<audio>` 要素
- `#track` — `<track kind="metadata">` 要素 (`<audio>` の中)
- `#poem` — 段落をレンダリングする入れ物 (`.poem` クラス)
- `#error` — エラー表示 (初期は `hidden`)
- `#reset` — 「最初に戻る」ボタン
- `.poem-viewport`, `.app`, `.controls` — レイアウト用クラス

## 本文テキスト形式

[WebVTT](https://www.w3.org/TR/webvtt1/) 準拠。各 cue が 1 つの段落に対応する。cue 識別子を付けると DOM の `id` として再利用されます。

```
WEBVTT

stanza-1
00:00.000 --> 00:08.600
春の夜に
静かに雨が降る

stanza-2
00:08.600 --> 00:13.244
遠い灯りが
川面に揺れている
```

cue 本文の各行は `<p class="stanza-line">` として `<div class="stanza">` 内に配置され、CSS の縦書き設定によって右から左へ並びます。

## アーキテクチャと Ruby ランタイム

- **`lib/*.rb`** — Ruby で書いたプレイヤー本体 (DOM、Renderer、Player、Kotoyomi)
- **`src/ruby_runtime.js`** — mruby-js.wasm を boot して `lib/*.rb` を流し込むだけのスターター
- **`vendor/mruby-wasm-js/`** — mruby + 自前 mrbgem `mruby-wasm-js` を WASM 化したバンドル (再配布可能、Phase A の `make dist` で生成)
- **`spike/`** — gem 開発のための隔離環境 (mruby cross-build、wasm_spec、smoke runner)

ランタイムを ruby.wasm ではなく mruby に切り替えた経緯と trade-off は [`docs/runtime-tradeoffs.md`](./docs/runtime-tradeoffs.md) を参照。フェーズ別の進行ログは [`docs/phase1-spike-summary.md`](./docs/phase1-spike-summary.md)、[`docs/phase2-spike-summary.md`](./docs/phase2-spike-summary.md) にあります。
