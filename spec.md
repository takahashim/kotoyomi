# 縦書き詩朗読プレイヤー Kotoyomi 仕様書

## 1. 目的

詩のテキストと朗読音声を組み合わせ、Webブラウザ上で縦書き表示しながら、朗読の進行に合わせて現在の連をハイライトするスタンドアローンなページを作成する。

詩テキストの記述・パース・同期にはWeb標準のWebVTTを採用し、ブラウザネイティブの`<track kind="metadata">`に処理を任せる。アプリケーション固有のフォーマットや自前パーサは持たない。

開発時はDeno / TypeScriptを使用し、ブラウザ配布物ではTypeScriptをJavaScriptに変換して実行する。

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

- DOM要素の取得とレンダリング
- cue情報からの本文DOM生成
- `cuechange`イベントを受けたハイライト付け替え
- ロードエラーのユーザー向け表示

DOM操作とレンダリングだけを担い、フォーマット解釈や同期ループは持たない。

## 3. アーキテクチャ

```text
poems/sample.vtt (WebVTT)
        ↓
<track kind="metadata"> (ブラウザがロード・パース)
        ↓
TextTrack.cues / cuechange イベント
        ↓
TypeScript レンダラ + プレイヤー
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
    main.ts
    types.ts
    renderer.ts
    player.ts

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

詩本文をDOMとして描画する。

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

`TextTrack`の`cuechange`イベントを購読し、現在のcueに対応するDOM要素のハイライトを管理する。

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

### 7.4 `main.ts`

アプリケーションのエントリポイント。

責務:

- `<audio>`、`<track>`、`#poem`、`#error` のDOM要素を取得する。
- `<audio>` に音声URLを設定する。
- `<track>` の `load` イベントを待つ (`readyState === 2` で即解決)。
- `track.cues` から `Cue[]` を生成し `renderPoem` を呼ぶ。
- `PoemPlayer` を初期化する。
- ロード失敗時は `#error` にメッセージを表示する。

## 8. UI仕様

### 8.1 基本画面

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

### 8.2 縦書き表示

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

### 8.3 ハイライト

- 現在の連のみに `active` クラスを付与する。
- それ以外の連は `display: none` で非表示。
- 初期仕様では1連のみをactiveにする。

## 9. 音声仕様

### 9.1 音声ファイル

- 音声ファイルはHTMLの `<audio>` 要素で再生する。
- 初期対応形式はブラウザ互換性を考慮し、MP3を基本とする。
- 将来的にOGG、WAV等にも対応可能とする。

### 9.2 同期方法

ブラウザの `TextTrack` API が同期を担当する。アプリ側は `cuechange` イベントを受けて、`track.activeCues[0]` を現在の連として表示する。

## 10. エラー仕様

### 10.1 ロードエラー

`<track>` 要素の `error` イベントが発生した場合 (VTTファイルの取得失敗、パース失敗) に画面上にメッセージを表示する。

### 10.2 表示方法

- エラーはコンソールに出力する。
- `#error` 要素の `textContent` に簡潔なメッセージを設定し `hidden` を外す。
- エラー時は `PoemPlayer` を初期化しない。

例:

```text
字幕トラックの読み込みに失敗しました。
track load error
```

## 11. Deno開発仕様

### 11.1 `deno.json`

```json
{
  "tasks": {
    "check": "deno check src/main.ts src/types.ts src/renderer.ts src/player.ts",
    "lint": "deno lint",
    "fmt": "deno fmt",
    "serve": "deno run --allow-net --allow-read jsr:@std/http/file-server",
    "build": "deno bundle src/main.ts -o dist/app.js"
  }
}
```

### 11.2 単体テスト

WebVTTパースとcue同期はブラウザに委ねるため、Deno上での単体テストは置かない。`deno task check` で型整合を、ブラウザでの実行で挙動を検証する。

## 12. セキュリティ・安全性

### 12.1 HTML挿入

- cue本文は `innerHTML` ではなく `textContent` で挿入する。
- WebVTTのインラインタグも本実装では平文として扱う。

### 12.2 ファイル読み込み

- 初期仕様では同梱された `.vtt` と `.mp3` のみを読み込む。
- 任意ファイルアップロード対応は将来拡張とする。

## 13. スタンドアローン配布仕様

### 13.1 配布物

```text
dist/
  app.js
index.html
app.css
poems/
  sample.vtt
  sample.mp3
```

### 13.2 実行方法

任意の静的Webサーバー上で実行する。同一オリジンであることが前提。

ローカル開発時は以下で起動する。

```bash
deno task serve
```

### 13.3 完全オフライン対応

将来的にPWA化する場合は `manifest.json` と `service-worker.js` を追加し、対象ファイルをキャッシュする。

## 14. 非目標

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

## 15. 将来拡張

将来的には以下を検討する。

- ルビ対応
- 傍点対応
- 注釈表示
- PWA化
- 複数作品切り替え
- テーマ切り替え
- 手動スクロール中の自動スクロール一時停止
- 音声波形表示
- 同期マーカー編集UI
- WebVTTのインラインタグ対応 (`<v>` で話者識別 等)
- WebVTT timestampタグによる逐字同期

## 16. 初期実装の優先順位

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

## 17. 基本方針の要約

このアプリは、フォーマット解釈と同期処理をブラウザ標準 (WebVTT API) に委ね、TypeScript側はDOMレンダリングとUI制御だけを担う。

```text
ブラウザ (WebVTT API):
  詩フォーマットの解釈と音声との同期を担当する

TypeScript:
  DOMレンダリングとUIイベント処理を担当する
```

この分担により、自前実装を最小限に保ちつつ、字幕系ツール (Aegisubなど) との互換性も得られる。
