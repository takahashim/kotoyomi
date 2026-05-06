# 縦書き詩朗読プレイヤー Kotoyomi 仕様書

## 1. 目的

詩のテキストと朗読音声を組み合わせ、Webブラウザ上で縦書き表示しながら、朗読の進行に合わせて現在の連をハイライトするスタンドアローンなページを作成する。

詩テキストの記述・パース・同期にはWeb標準のWebVTTを採用し、ブラウザネイティブの`<track kind="metadata">`に処理を任せる。アプリケーション固有のフォーマットや自前パーサは持たない。

開発時はDeno / TypeScriptを使用し、ブラウザ配布物ではTypeScriptをJavaScriptに変換して実行する。実験的に ruby.wasm を用いた Ruby 版エンジンを併設し、最終的には Ruby を主役の制御層として位置付ける構成を目指す。

## 2. 基本方針

### 2.1 実行環境

- 開発時はDeno / TypeScriptを使用する。
- ブラウザ配布物ではTypeScriptをJavaScriptに変換して実行する。
- サーバーサイド処理は前提としない。
- 最終成果物は静的ファイルのみで動作するスタンドアローンなWebページとする。

### 2.2 役割分担

#### ブラウザ側 (HTML / WebVTT API)

- WebVTTファイルのロードとパース
- cueと音声の同期 (`cuechange`イベント、`activeCues`)
- 音声再生制御 (`<audio>`要素)

#### TypeScript / JavaScript 側

- DOM要素の取得とエンジン dispatcher (URL クエリで TS / Ruby 切替)
- TS エンジン: cue情報からの本文DOM生成と `cuechange` ハイライト付け替え
- ruby.wasm のロードとブートストラップ
- ロードエラーのユーザー向け表示

#### Ruby エンジン (オプション、`?engine=ruby`)

- `js` gem 経由の DOM 生成 (renderer)
- `cuechange` イベント購読とハイライト付け替え (player)

#### CSS

- 縦書き・中央表示・ハイライトなどの視覚効果

### 2.3 役割の長期方針

最終的には次の役割分担に寄せていく:

| 層 | 役割 |
|---|---|
| WebVTT | 朗読データ |
| Ruby | プレイヤー制御・状態遷移・DOM 操作 |
| CSS | 視覚効果 |
| JS/TS | ruby.wasm 起動・最小限のホスト |

現状の TS/Ruby 併存はこの最終形態への過渡形態として位置付ける。

## 3. アーキテクチャ

```text
poems/sample.vtt (WebVTT)
        ↓
<track kind="metadata"> (ブラウザがロード・パース)
        ↓
TextTrack.cues / cuechange イベント
        ↓
URL ?engine 分岐
   ├─ ts   → TypeScript レンダラ + プレイヤー
   └─ ruby → ruby.wasm 上の Kotoyomi::Renderer + Kotoyomi::Player
        ↓
HTML / CSS / DOM
```

## 4. ディレクトリ構成

```text
kotoyomi/
  index.html
  app.css
  deno.json

  src/
    main.ts            ← ブートストラップ・エンジン dispatcher
    types.ts
    renderer.ts        ← TS エンジン
    player.ts          ← TS エンジン
    ruby_engine.ts     ← Ruby エンジンのロード・グルー

  src-rb/
    renderer.rb        ← Ruby エンジン
    player.rb          ← Ruby エンジン

  poems/
    sample.vtt
    sample.mp3

  dist/
    app.js
```

## 5. 詩テキスト形式

詩テキストは [WebVTT](https://www.w3.org/TR/webvtt1/) 準拠の `.vtt` ファイルとして記述する。1つのcueが1つの連 (stanza) に対応する。

```text
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

### 5.1 規約

- 1つの連を1つのcueで表現する。
- cue識別子 (タイミング行の前の行) を `stanza-N` のように付与すると、生成されるDOM要素のIDとして再利用される。識別子が無い場合はインデックスから自動生成する。
- cue本文の各行はそれぞれ1つの`<p class="stanza-line">`として描画される。
- WebVTTのインラインタグ (`<v>`, `<i>`, `<ruby>` 等) や cue settings (`vertical:rl` 等) は本実装では使用しない。

### 5.2 ファイルの配置

`poems/sample.vtt` と `poems/sample.mp3` を同梱する。同じURLオリジンから配信されることを前提とする。

## 6. 内部データ構造

### 6.1 Cue

レンダラとプレイヤーが共通に扱う薄い構造的型。`VTTCue` の必要なサブセットを表す。

```ts
export type Cue = {
  id: string;
  startTime: number;
  text: string;
};
```

`VTTCue` から `{ id, startTime, text }` を抜き出すことで生成する。

## 7. TypeScriptモジュール仕様

### 7.1 `types.ts`

`Cue` 型を提供する。

### 7.2 `renderer.ts`

詩本文をDOMとして描画する (TS エンジン)。

```ts
export function renderPoem(
  cues: Cue[],
  container: HTMLElement
): HTMLElement[];
```

責務:

- `container` の中身を初期化する。
- 各cueから`<div class="stanza">`を生成し、内側に各本文行ぶんの`<p class="stanza-line">`を生成する。
- `<div>`には`id`、`class="stanza"`、`data-start-time`を付与する。
- 本文は`textContent`として挿入する (XSS対策)。
- 生成した連要素の配列を返す。

生成されるDOM例:

```html
<div id="poem" class="poem">
  <div id="stanza-1" class="stanza" data-start-time="0">
    <p class="stanza-line">春の夜に</p>
    <p class="stanza-line">静かに雨が降る</p>
  </div>
</div>
```

### 7.3 `player.ts`

`TextTrack`の`cuechange`イベントを購読し、現在のcueに対応するDOM要素のハイライトを管理する (TS エンジン)。

```ts
export class PoemPlayer {
  constructor(params: {
    track: TextTrack;
    elements: HTMLElement[];
  });
}
```

責務:

- `track.mode = "hidden"` を設定して `cuechange` イベントを有効化する。
- `cuechange` イベントを購読する。
- `track.activeCues[0]` から現在のcueを取得し、対応する要素を `cues.indexOf(cue)` で求める。
- 現在の連が変化した場合のみDOM更新を行う (古い`active`を外して新規付与)。
- `dispose()` でイベントリスナを解除する。

`requestAnimationFrame` ループや `audio.currentTime` の監視は行わない (ブラウザがcue管理を行うため)。

### 7.4 `ruby_engine.ts`

ruby.wasm の動的ロードと、`src-rb/*.rb` の eval、TS↔Ruby のグルーを提供する。

```ts
export async function startRubyEngine(params: {
  track: TextTrack;
  cues: Cue[];
  container: HTMLElement;
}): Promise<void>;
```

責務:

- `@ruby/wasm-wasi` の `DefaultRubyVM` を CDN (jsDelivr) から動的 import する。
- `@ruby/3.4-wasm-wasi/dist/ruby+stdlib.wasm` を fetch + `WebAssembly.compileStreaming`。
- Ruby VM を起動。
- `src-rb/renderer.rb` と `src-rb/player.rb` を fetch して `vm.eval` で評価。
- `Kotoyomi::Renderer.render(cues, container)` を呼び、戻り値の要素配列を `Kotoyomi::Player.new(track, elements)` に渡す。

ruby.wasm 配布物の取得失敗時は呼び出し元に例外を投げる。

### 7.5 `main.ts`

アプリケーションのエントリポイント、エンジン dispatcher。

責務:

- `<audio>`、`<track>`、`#poem`、`#error` のDOM要素を取得する。
- `<audio>` に音声URLを設定する。
- `<track>` の `load` イベントを待つ (`readyState === 2` で即解決)。
- `track.cues` から `Cue[]` を生成する。
- URL クエリ `engine` を読み:
  - `ts` (既定) なら `renderPoem` + `new PoemPlayer`
  - `ruby` なら `startRubyEngine` を呼ぶ
- ロード失敗時は `#error` にメッセージを表示する。

## 8. Ruby エンジン仕様 (オプション)

`?engine=ruby` 指定時に動作する代替エンジン。`src-rb/*.rb` を ruby.wasm 上で実行する。

### 8.1 ランタイム

- `@ruby/3.4-wasm-wasi` v2.x (CRuby 3.4 + WASI) を採用。
- jsDelivr CDN から ESM とWASMを動的取得する (vendor 化は将来検討)。
- ブラウザにおける `js` gem (`require "js"`) を介して DOM を直接操作する。

### 8.2 `src-rb/renderer.rb`

```ruby
module Kotoyomi
  module Renderer
    def self.render(cues, container)
      # 各 cue から <div class="stanza"><p class="stanza-line">...</p></div> を生成
      # 生成した連要素の JS::Array を返す
    end
  end
end
```

責務は TS 版 `renderer.ts` と等価。`textContent` 経由で本文を挿入し、XSS対策を維持する。

### 8.3 `src-rb/player.rb`

```ruby
module Kotoyomi
  class Player
    def initialize(track, elements)
      # track.mode = "hidden"
      # track.addEventListener("cuechange") { update }
    end
  end
end
```

責務は TS 版 `player.ts` と等価。`cuechange` イベントだけで動作する。

### 8.4 ランタイム互換性

将来的に [mruby](https://mruby.org/) や [PicoRuby](https://github.com/picoruby/picoruby) の WASM ビルドへ置き換える可能性がある。`js` gem は CRuby 固有なので置き換え時には JS interop 層の書き換えが発生する。Ruby 側コードは標準的な構文に留め、移行時の差分が読みやすい状態を保つ。

## 9. UI仕様

### 9.1 基本画面

```html
<main class="app">
  <section class="poem-viewport">
    <div id="poem" class="poem"></div>
  </section>

  <audio id="audio" controls crossorigin="anonymous">
    <track id="track" kind="metadata" src="poems/sample.vtt" default />
  </audio>

  <p id="error" class="error" hidden></p>
</main>
```

### 9.2 縦書き表示

詩本文はCSSで縦書き表示する。現在の連のみを中央に表示する。

```css
.poem-viewport {
  height: 80vh;
  display: flex;
  align-items: center;
  justify-content: center;
  overflow: hidden;
}

.poem {
  writing-mode: vertical-rl;
  text-orientation: mixed;
  line-height: 2.2;
  font-size: 28px;
  letter-spacing: 0.08em;
  display: flex;
  align-items: center;
  justify-content: center;
}

.stanza {
  display: none;
}

.stanza.active {
  display: flex;
  flex-direction: row;
  align-items: center;
  gap: 0.4em;
  font-weight: 600;
}

.stanza-line {
  margin: 0;
}
```

### 9.3 ハイライト

- 現在の連のみに `active` クラスを付与する。
- それ以外の連は `display: none` で非表示。
- 初期仕様では1連のみをactiveにする。

## 10. 音声仕様

### 10.1 音声ファイル

- 音声ファイルはHTMLの `<audio>` 要素で再生する。
- 初期対応形式はブラウザ互換性を考慮し、MP3を基本とする。
- 将来的にOGG、WAV等にも対応可能とする。

### 10.2 同期方法

ブラウザの `TextTrack` API が同期を担当する。アプリ側は `cuechange` イベントを受けて、`track.activeCues[0]` を現在の連として表示する。

## 11. エラー仕様

### 11.1 ロードエラー

- `<track>` 要素の `error` イベントが発生した場合 (VTTファイルの取得失敗、パース失敗) に画面上にメッセージを表示する。
- `?engine=ruby` で ruby.wasm またはRubyソースの取得に失敗した場合も同様。

### 11.2 表示方法

- エラーはコンソールに出力する。
- `#error` 要素の `textContent` に簡潔なメッセージを設定し `hidden` を外す。
- エラー時は `PoemPlayer` を初期化しない。

## 12. Deno開発仕様

### 12.1 `deno.json`

```json
{
  "tasks": {
    "check": "deno check src/main.ts src/types.ts src/renderer.ts src/player.ts src/ruby_engine.ts",
    "lint": "deno lint",
    "fmt": "deno fmt",
    "serve": "deno run --allow-net --allow-read jsr:@std/http/file-server",
    "build": "deno bundle src/main.ts -o dist/app.js"
  }
}
```

### 12.2 単体テスト

WebVTTパースとcue同期はブラウザに委ね、Ruby エンジンのDOM操作は ruby.wasm/ブラウザに依存するため、Deno上での単体テストは置かない。`deno task check` で型整合を、ブラウザでの実行で挙動を検証する。

## 13. セキュリティ・安全性

### 13.1 HTML挿入

- cue本文は `innerHTML` ではなく `textContent` で挿入する (TS / Ruby とも)。
- WebVTTのインラインタグも本実装では平文として扱う。

### 13.2 ファイル読み込み

- 初期仕様では同梱された `.vtt` と `.mp3`、および `src-rb/*.rb` のみを読み込む。
- 任意ファイルアップロード対応は将来拡張とする。

### 13.3 外部依存

- `?engine=ruby` 指定時のみ jsDelivr CDN から ruby.wasm 配布物を取得する。
- TS エンジンは外部ネットワークアクセスなしで完結する。

## 14. スタンドアローン配布仕様

### 14.1 配布物

```text
dist/
  app.js
index.html
app.css
poems/
  sample.vtt
  sample.mp3
src-rb/
  renderer.rb
  player.rb
```

### 14.2 実行方法

任意の静的Webサーバー上で実行する。同一オリジンであることが前提。

ローカル開発時は以下で起動する。

```bash
deno task serve
```

### 14.3 完全オフライン対応

将来的にPWA化する場合は `manifest.json` と `service-worker.js` を追加し、対象ファイルをキャッシュする。Ruby エンジンを完全オフライン化する場合は ruby.wasm 配布物も vendor/ に取り込む。

## 15. 非目標

初期仕様では以下を対象外とする。

- 文字単位の同期 (WebVTT timestampタグを使った逐字ハイライト)
- カラオケ的な逐字ハイライト
- 複数音声トラック対応
- 複数詩作品のライブラリ管理
- 編集UI
- ファイルアップロード
- サーバーサイド保存
- 認証
- ルビ・傍点・注釈などの高度な組版
- WebVTTのcue settings (vertical, line, position 等) のサポート
- WebVTTのインラインタグのサポート

## 16. 将来拡張

将来的には以下を検討する。

- ルビ対応
- 傍点対応
- 注釈表示
- PWA化 (ruby.wasm の vendor 化を含む)
- 複数作品切り替え
- テーマ切り替え
- 手動スクロール中の自動スクロール一時停止
- 音声波形表示
- 同期マーカー編集UI
- WebVTTのインラインタグ対応 (`<v>` で話者識別 等)
- WebVTT timestampタグによる逐字同期
- mruby.wasm / PicoRuby.wasm への置き換え
- `js` gem 抽象化レイヤーの導入 (ランタイム差し替えに備えた DOM 操作 DSL)
- TS エンジンを撤去して Ruby を主役とする最終形態への移行

## 17. 初期実装の優先順位

### Phase 1: WebVTTベースのプロトタイプ

- `<track kind="metadata">` でVTTをロード
- `Cue` 型定義
- `renderPoem()` 実装
- `PoemPlayer` (`cuechange` 駆動) 実装
- 縦書きCSS
- サンプル音声との同期確認

### Phase 2: Deno開発ツール整備

- `deno check`
- `deno lint`
- `deno fmt`
- `deno bundle` によるバンドル

### Phase 3: 表示体験の調整

- ハイライト表現調整
- フォントサイズ・行間調整
- 縦書き時の表示崩れ確認

### Phase 4: Ruby エンジン併設

- ruby.wasm の動的ロード
- `src-rb/renderer.rb`、`src-rb/player.rb` 実装
- URL クエリによる engine 切替
- TS 版とのリグレッション比較

### Phase 5: 軽量 Ruby ランタイムへの移行検討

- mruby.wasm / PicoRuby.wasm の評価
- `js` gem 抽象化レイヤーの設計
- TS エンジン撤去のタイミング判断

## 18. 基本方針の要約

このアプリは、フォーマット解釈と同期処理をブラウザ標準 (WebVTT API) に委ね、アプリケーション層は最小限の仕事だけを担う。その「最小限」を TS で書く版と Ruby で書く版を併設し、最終的には Ruby を主役の制御層として置く形を目指す。

```text
WebVTT:
  朗読データ

ブラウザ (WebVTT API):
  詩フォーマットの解釈と音声との同期を担当する

CSS:
  視覚効果を担当する

Ruby (将来的に主役):
  プレイヤー制御・状態遷移・DOM 操作を担当する

JS/TS:
  ruby.wasm 起動と最小限のホストを担当する
```

この分担により、自前実装を最小限に保ちつつ、字幕系ツール (Aegisubなど) との互換性、および ruby.wasm エコシステムでの実験を両立する。
