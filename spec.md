# 縦書き詩朗読プレイヤー Kotoyomi 仕様書

## 1. 目的

詩のテキストと朗読音声を組み合わせ、Webブラウザ上で縦書き表示しながら、朗読の進行に合わせて現在の連をハイライトするスタンドアローンなページを作成する。

詩テキストの記述・パース・同期にはWeb標準のWebVTTを採用し、ブラウザネイティブの`<track kind="metadata">`に処理を任せる。プレイヤー制御と DOM 操作は ruby.wasm 上の Ruby が担い、JS/TS は ruby.wasm の起動と最小限のホストだけを担当する。

開発時はDeno / TypeScriptを使用し、ブラウザ配布物では TypeScript をビルドした JavaScript と Ruby ソースを配信する。

## 2. 基本方針

### 2.1 実行環境

- 開発時はDeno / TypeScriptを使用する。
- ブラウザ配布物ではTypeScriptをJavaScriptに変換して実行する。
- サーバーサイド処理は前提としない。
- 最終成果物は静的ファイルのみで動作するスタンドアローンなWebページとする。
- 実行時にブラウザが jsDelivr CDN から ruby.wasm 配布物を取得できることを前提とする (将来オフライン対応する際は vendor 化)。

### 2.2 役割分担

| 層 | 役割 | 物理的な実装場所 |
|---|---|---|
| WebVTT | 朗読データ | `poems/sample.vtt` |
| ブラウザ (TextTrack API) | フォーマット解釈と音声同期 | ネイティブ |
| Ruby (ruby.wasm) | プレイヤー制御・状態遷移・DOM 操作 | `src-rb/*.rb` (`js` gem 経由) |
| CSS | 視覚効果 (縦書き、中央表示、フェードイン) | `app.css` |
| JS/TS | ruby.wasm 起動と最小限のホスト | `src/*.ts` |

JS/TS 側は次の役割に専念する:
- DOM 要素の取得
- WebVTT トラックのロード待機
- 音声 URL のセット
- 「最初に戻る」ボタンのハンドリング (`audio.currentTime = 0`)
- ruby.wasm のロードと Ruby ソースの eval
- Ruby 側エントリポイントの呼び出し
- ロードエラー時の表示

## 3. アーキテクチャ

```text
poems/sample.vtt (WebVTT)
        ↓
<track kind="metadata"> (ブラウザがロード・パース)
        ↓
TextTrack.cues / cuechange イベント
        ↓
ruby.wasm 上の Kotoyomi::Renderer + Kotoyomi::Player
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
    main.ts            ← ブートストラップ (~15 行)
    ruby_runtime.ts    ← ruby.wasm の VM 起動と Kotoyomi.start 呼び出し

  src-rb/
    kotoyomi.rb        ← アプリのエントリポイント (Kotoyomi::App)
    renderer.rb        ← DOM 生成 (Kotoyomi::Renderer)
    player.rb          ← cuechange ハンドリング・ハイライト (Kotoyomi::Player)

  poems/
    sample.vtt
    sample.mp3

  dist/
    app.js             ← src/*.ts のバンドル成果物
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

専用のデータ転送型は持たない。Ruby 側は `VTTCue` (`TextTrackCueList` の要素) を `js` gem 経由で直接扱い、`cue[:id]` / `cue[:startTime]` / `cue[:text]` でプロパティにアクセスする。

## 7. TypeScriptモジュール仕様

### 7.1 `ruby_runtime.ts`

ruby.wasm の動的ロードと、`src-rb/*.rb` の eval、Ruby エントリ呼び出し。

```ts
export async function bootRuby(): Promise<void>;
```

責務:

- `@ruby/wasm-wasi` の `DefaultRubyVM` を CDN (jsDelivr) から動的 import する。
- `@ruby/3.4-wasm-wasi/dist/ruby+stdlib.wasm` を fetch + `WebAssembly.compileStreaming`。
- Ruby VM を起動。
- `src-rb/*.rb` を順序付き (renderer → player → kotoyomi) に fetch して `vm.eval` で評価。
- `vm.evalAsync("Kotoyomi.start")` で Ruby に制御を渡す (`evalAsync` は Ruby 内 `Promise#await` を許容する)。

TS↔Ruby 界面は `Kotoyomi.start` の 1 関数呼び出しのみ。Renderer / Player / App のクラス名は TS から見えない。

### 7.2 `main.ts`

アプリケーションのエントリポイント、薄いブートストラップ。

責務:

- DOM 待機 (`DOMContentLoaded`)。
- `bootRuby()` 呼び出し。
- ruby.wasm 起動が失敗した場合のみ `#error` にメッセージを表示する (Ruby が動き始める前のエラーは TS でしか拾えないため)。

それ以外のアプリ制御は全て Ruby に委ねる。

## 8. Ruby エンジン仕様

`src-rb/*.rb` を ruby.wasm 上で実行する。プレイヤーの本体ロジックはこちらに置く。

### 8.1 ランタイム

- `@ruby/3.4-wasm-wasi` v2.x (CRuby 3.4 + WASI) を採用。
- jsDelivr CDN から ESM とWASMを動的取得する (vendor 化は将来検討)。
- ブラウザにおける `js` gem (`require "js"`) を介して DOM を直接操作する。

### 8.2 `src-rb/kotoyomi.rb`

アプリのエントリポイント。TS が呼ぶ `Kotoyomi.start` は `Kotoyomi::App.new.start` への薄い委譲で、実体は `App` クラスのインスタンスメソッドが持つ。

```ruby
module Kotoyomi
  def self.start
    App.new.start
  end

  class App
    def initialize
      # @audio, @track_el, @poem, @error_el, @reset_btn を保持
    end

    def start
      # トラック load 待機 → Renderer.render → Player.new
      # reset ボタン配線、初期表示確定 (audio.currentTime = 0)
    rescue => e
      report_error(e)
      raise
    end

    private

    def wait_for_track_load   # JS::Promise#await でロードを待機
    def report_error(e)        # #error 要素にメッセージ表示
  end
end
```

責務: DOM 取得、トラック lifecycle 待機、Renderer/Player のオーケストレーション、UI イベント (reset ボタン)、初期表示確定、エラーハンドリング。`Promise#await` を使うため `vm.evalAsync` で呼び出される。

### 8.3 `src-rb/renderer.rb`

```ruby
module Kotoyomi
  class Renderer
    def initialize(cues, container)
      # @cues, @container, @document を保持
    end

    def render
      # 各 cue から <div class="stanza"><p class="stanza-line">...</p></div> を生成
      # 生成した連要素の JS::Array を返す
    end

    private

    def build_stanza(cue, index)  # 1 連分の DOM 生成
  end
end
```

`textContent` 経由で本文を挿入し、XSS対策を維持する。1 連分の生成は `build_stanza` に切り出し、`render` は反復のみに専念。

### 8.4 `src-rb/player.rb`

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

`cuechange` イベントだけで動作する。現在の cue 特定は `cue.startTime` を用いた線形探索 (`js` gem で `Function.prototype.call` 越しの indexOf を呼ぶより素直なため)。

### 8.5 ランタイム互換性

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

  <div class="controls">
    <button id="reset" type="button">最初に戻る</button>
  </div>

  <p id="error" class="error" hidden></p>
</main>
```

### 9.2 縦書き表示

詩本文はCSSで縦書き表示する。現在の連のみを上方寄せ・水平中央で表示する。

```css
.poem-viewport {
  height: 80vh;
  display: flex;
  align-items: flex-start;
  justify-content: center;
  padding-top: 2rem;
  box-sizing: border-box;
  overflow: hidden;
}

.poem {
  writing-mode: vertical-rl;
  text-orientation: mixed;
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
  animation: stanza-fade-in 2s ease-out;
}

.stanza-line {
  margin: 0;
}

@keyframes stanza-fade-in {
  from { opacity: 0; }
  to   { opacity: 1; }
}
```

### 9.3 ハイライトと演出

- 現在の連のみに `active` クラスを付与する。
- それ以外の連は `display: none` で非表示。
- アクティブになった瞬間に CSS アニメーションで 2 秒のフェードインを適用する。
- 初期仕様では1連のみをactiveにする。

### 9.4 操作

- `<audio controls>` の再生・停止・シーク。
- 「最初に戻る」ボタン: `audio.currentTime = 0`。再生状態は維持する (再生中なら継続、停止中なら停止のまま位置だけ巻き戻る)。

## 10. 音声仕様

### 10.1 音声ファイル

- 音声ファイルはHTMLの `<audio>` 要素で再生する。
- 初期対応形式はブラウザ互換性を考慮し、MP3を基本とする。
- 将来的にOGG、WAV等にも対応可能とする。

### 10.2 同期方法

ブラウザの `TextTrack` API が同期を担当する。Ruby 側は `cuechange` イベントを受けて、`track.activeCues[0]` を現在の連として表示する。

## 11. エラー仕様

### 11.1 ロードエラー

- `<track>` 要素の `error` イベント (VTTファイルの取得失敗、パース失敗)
- ruby.wasm またはRubyソースの取得・eval 失敗

いずれの場合も画面上にメッセージを表示する。

### 11.2 表示方法

- エラーはコンソールに出力する。
- `#error` 要素の `textContent` に簡潔なメッセージを設定し `hidden` を外す。
- 表示の責務はエラー発生箇所による:
  - ruby.wasm 起動前 (TS 段階) のエラー → `src/main.ts` が表示
  - Ruby 起動後のエラー → `Kotoyomi::App#start` の `rescue` 節が表示し再 raise
- エラー時は Kotoyomi の起動を完遂しない。

## 12. Deno開発仕様

### 12.1 `deno.json`

```json
{
  "tasks": {
    "check": "deno check src/main.ts src/ruby_runtime.ts",
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

- cue本文は `innerHTML` ではなく `textContent` で挿入する (Ruby 側も同様)。
- WebVTTのインラインタグも本実装では平文として扱う。

### 13.2 ファイル読み込み

- 初期仕様では同梱された `.vtt` と `.mp3`、および `src-rb/*.rb` のみを読み込む。
- 任意ファイルアップロード対応は将来拡張とする。

### 13.3 外部依存

- 起動時に jsDelivr CDN から ruby.wasm 配布物 (`@ruby/wasm-wasi` と `@ruby/3.4-wasm-wasi`) を取得する。
- これは設計上避けられない外部依存。完全オフライン化する際は vendor/ に取り込む。

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

任意の静的Webサーバー上で実行する。同一オリジンであることが前提。ruby.wasm 配布物は実行時に CDN から取得する。

ローカル開発時は以下で起動する。

```bash
deno task serve
```

### 14.3 完全オフライン対応

将来的にPWA化する場合は `manifest.json` と `service-worker.js` を追加し、対象ファイル (ruby.wasm 配布物含む) をキャッシュする。

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
- 音声波形表示
- 同期マーカー編集UI
- WebVTTのインラインタグ対応 (`<v>` で話者識別 等)
- WebVTT timestampタグによる逐字同期
- mruby.wasm / PicoRuby.wasm への置き換え
- `js` gem 抽象化レイヤーの導入 (ランタイム差し替えに備えた DOM 操作 DSL)

## 17. 基本方針の要約

このアプリは、フォーマット解釈と同期処理をブラウザ標準 (WebVTT API) に委ね、プレイヤー制御を ruby.wasm 上の Ruby に委ねる。JS/TS は ruby.wasm を起動するためだけのホストに留まる。

```text
WebVTT:
  朗読データ

ブラウザ (WebVTT API):
  詩フォーマットの解釈と音声との同期を担当する

CSS:
  視覚効果を担当する

Ruby (ruby.wasm):
  プレイヤー制御・状態遷移・DOM 操作を担当する

JS/TS:
  ruby.wasm 起動と最小限のホストを担当する
```

この分担により、字幕系ツール (Aegisubなど) との互換性を得つつ、アプリケーションロジックを Ruby で記述できる。将来の mruby/PicoRuby への移行も Ruby 側のコードを差し替えるだけで完結する見込み。
