# 縦書き詩朗読プレイヤー Kotoyomi 仕様書

## 1. 目的

詩のテキストと朗読音声を組み合わせ、Webブラウザ上で縦書き表示しながら、朗読の進行に合わせて詩本文をハイライト・スクロールするスタンドアローンなページを作成する。

初期実装では Deno / TypeScript を用いて開発し、ブラウザ上では TypeScript をビルドした JavaScript として動作させる。

将来的には、詩テキストのパース処理を Ruby に移植し、ruby.wasm 上で実行する。

## 2. 基本方針

### 2.1 実行環境

- 開発時は Deno / TypeScript を使用する。
- ブラウザ配布物では TypeScript を JavaScript に変換して実行する。
- サーバーサイド処理は前提としない。
- 最終成果物は静的ファイルのみで動作するスタンドアローンなWebページとする。

### 2.2 役割分担

#### TypeScript / JavaScript 側

以下を担当する。

- 音声再生制御
- `audio.currentTime` に基づく現在位置の判定
- 詩本文のDOM生成
- 現在行のハイライト
- 縦書き表示のスクロール制御
- 再生・停止・シークなどのUI制御
- 初期段階での詩テキストパース

#### Ruby / ruby.wasm 側

将来的に以下を担当する。

- 同期マーカー付き詩テキストのパース
- 同期データの生成
- 必要に応じたフォーマット検証
- TypeScript側へ渡すJSONデータの生成

Ruby側はDOM操作や音声制御を担当しない。

## 3. アーキテクチャ

### 3.1 初期実装

```text
同期マーカー付き詩テキスト
        ↓
Deno / TypeScript パーサ
        ↓
PoemLine[] データ
        ↓
TypeScript プレイヤー
        ↓
HTML / CSS / Audio API / DOM
```

### 3.2 将来実装

```text
同期マーカー付き詩テキスト
        ↓
ruby.wasm 上の Ruby パーサ
        ↓
JSON
        ↓
TypeScript 側で実行時検証
        ↓
PoemLine[] データ
        ↓
TypeScript プレイヤー
        ↓
HTML / CSS / Audio API / DOM
```

## 4. ディレクトリ構成案

```text
poem-player/
  index.html
  app.css
  deno.json

  src/
    main.ts
    parser.ts
    player.ts
    renderer.ts
    types.ts
    validator.ts

  ruby/
    poem_parser.rb

  poems/
    sample.poem
    sample.mp3

  tools/
    validate_poem.ts
    export_webvtt.ts

  testdata/
    sample.expected.json

  dist/
    app.js
    app.css
    poems/
      sample.poem
      sample.mp3
```

## 5. データ形式

### 5.1 詩テキスト形式

詩テキストには、朗読音声との同期に用いる時刻マーカーを記述できる。

基本形式は以下とする。

```text
[00:00.000] 春の夜に
[00:04.200] 静かに雨が降る
[00:08.600] 遠い灯りが
[00:11.300] 川面に揺れている
```

### 5.2 時刻マーカー

時刻マーカーは以下の形式とする。

```text
[mm:ss.mmm]
```

例:

```text
[00:04.200]
[01:12.050]
[12:03.000]
```

### 5.3 パース規則

- 1つの同期単位につき、1つの時刻マーカーを持つ。
- 時刻マーカーは行頭に記述する。
- 時刻マーカーの後ろに本文を記述する。
- 空行は無視する。
- 時刻は秒数の `number` に変換する。
- 時刻は昇順でなければならない。
- 時刻マーカーのない本文行は、初期仕様ではエラーとする。
- 不正な形式の行がある場合はパースエラーとする。

### 5.4 将来拡張候補

将来的には以下を検討する。

```text
[00:00.000]
春の夜に

[00:04.200]
静かに雨が降る
```

または、連単位の同期。

```text
[00:00.000]
春の夜に
静かに雨が降る

[00:08.600]
遠い灯りが
川面に揺れている
```

初期仕様では、実装を単純にするため行単位同期を基本とする。

## 6. 内部データ構造

### 6.1 PoemLine

```ts
export type PoemLine = {
  id: string;
  time: number;
  text: string;
};
```

### 6.2 PoemDocument

```ts
export type PoemDocument = {
  title?: string;
  audioSrc: string;
  lines: PoemLine[];
};
```

### 6.3 JSON出力例

```json
[
  {
    "id": "line-1",
    "time": 0,
    "text": "春の夜に"
  },
  {
    "id": "line-2",
    "time": 4.2,
    "text": "静かに雨が降る"
  },
  {
    "id": "line-3",
    "time": 8.6,
    "text": "遠い灯りが"
  }
]
```

## 7. TypeScriptモジュール仕様

### 7.1 `types.ts`

型定義を提供する。

```ts
export type PoemLine = {
  id: string;
  time: number;
  text: string;
};

export type PoemDocument = {
  title?: string;
  audioSrc: string;
  lines: PoemLine[];
};
```

### 7.2 `parser.ts`

初期実装用のTypeScriptパーサを提供する。

```ts
export function parsePoem(source: string): PoemLine[];
```

責務:

- 同期マーカー付き詩テキストをパースする。
- `PoemLine[]` を返す。
- 不正な形式の場合は例外を投げる。
- 時刻が昇順でない場合は例外を投げる。

### 7.3 `validator.ts`

Ruby / ruby.wasm から返されたJSONを検証する。

```ts
export function assertPoemLines(value: unknown): asserts value is PoemLine[];
```

責務:

- `unknown` な入力が `PoemLine[]` として妥当か検証する。
- `id` が文字列であることを確認する。
- `time` が有限の数値であることを確認する。
- `text` が文字列であることを確認する。
- 不正な場合は例外を投げる。

### 7.4 `renderer.ts`

詩本文をDOMとして描画する。

```ts
export function renderPoem(
  lines: PoemLine[],
  container: HTMLElement
): HTMLElement[];
```

責務:

- `container` の中身を初期化する。
- 各 `PoemLine` から `<p>` 要素を生成する。
- 本文は `textContent` として挿入する。
- 各要素に `id`、`class`、`data-time` を付与する。
- 生成した要素配列を返す。

生成されるDOM例:

```html
<div id="poem" class="poem">
  <p id="line-1" class="line" data-time="0">春の夜に</p>
  <p id="line-2" class="line" data-time="4.2">静かに雨が降る</p>
</div>
```

### 7.5 `player.ts`

音声と詩本文の同期制御を行う。

```ts
export class PoemPlayer {
  constructor(params: {
    audio: HTMLAudioElement;
    lines: PoemLine[];
    elements: HTMLElement[];
  });
}
```

責務:

- `audio.currentTime` を監視する。
- 現在時刻に対応する `PoemLine` を特定する。
- 対応するDOM要素に `active` クラスを付与する。
- 以前の要素から `active` クラスを外す。
- 必要に応じて該当要素をスクロールする。

内部仕様:

- 再生中は `requestAnimationFrame` で同期状態を更新する。
- 停止中は更新ループを止める。
- 現在行が変化した場合のみDOM更新を行う。
- 現在行の探索には二分探索を用いる。
- `seeked` イベント発生時には即座に表示を更新する。

### 7.6 `main.ts`

アプリケーションのエントリポイント。

責務:

- DOM要素を取得する。
- 詩テキストを読み込む。
- 音声ファイルを設定する。
- パーサを呼び出す。
- 詩本文を描画する。
- `PoemPlayer` を初期化する。
- エラー時にユーザー向けメッセージを表示する。

## 8. UI仕様

### 8.1 基本画面

画面には以下を表示する。

- 縦書きの詩本文
- 音声再生コントロール
- 必要に応じてタイトル
- エラー表示領域

例:

```html
<main class="app">
  <section class="poem-viewport">
    <div id="poem" class="poem"></div>
  </section>

  <audio id="audio" controls></audio>

  <p id="error" class="error" hidden></p>
</main>
```

### 8.2 縦書き表示

詩本文はCSSで縦書き表示する。

```css
.poem-viewport {
  height: 80vh;
  overflow: auto;
}

.poem {
  writing-mode: vertical-rl;
  text-orientation: mixed;
  line-height: 2.2;
  font-size: 24px;
  letter-spacing: 0.08em;
  padding: 3rem;
}

.line {
  margin: 0 0 0 1.6em;
  opacity: 0.45;
  transition:
    opacity 0.25s ease,
    transform 0.25s ease;
}

.line.active {
  opacity: 1;
  font-weight: 600;
}
```

### 8.3 スクロール

- 現在行が変化したときに、該当要素を表示範囲の中央付近へ移動する。
- 初期実装では `scrollIntoView()` を使用する。
- 縦書き表示に対応するため、`block` と `inline` の両方を指定する。

```ts
element.scrollIntoView({
  behavior: "smooth",
  block: "center",
  inline: "center",
});
```

### 8.4 ハイライト

- 現在読まれている行に `active` クラスを付与する。
- それ以外の行は通常表示とする。
- 初期仕様では1行のみをactiveにする。

## 9. 音声仕様

### 9.1 音声ファイル

- 音声ファイルはHTMLの `<audio>` 要素で再生する。
- 初期対応形式はブラウザ互換性を考慮し、MP3を基本とする。
- 将来的にOGG、WAV等にも対応可能とする。

### 9.2 同期方法

- `audio.currentTime` を現在時刻として使用する。
- 現在時刻以下で、最も近い時刻マーカーを持つ行を現在行とする。

例:

```text
現在時刻: 5.0秒

[00:00.000] 春の夜に
[00:04.200] 静かに雨が降る
[00:08.600] 遠い灯りが

=> 現在行は「静かに雨が降る」
```

## 10. エラー仕様

### 10.1 パースエラー

以下の場合はパースエラーとする。

- 時刻マーカーの形式が不正
- 本文が空
- 時刻が昇順でない
- 時刻が数値として解釈できない
- 時刻マーカーなしの本文行がある

### 10.2 表示方法

- エラーはコンソールに出力する。
- 画面上にも簡潔なメッセージを表示する。
- エラー時はプレイヤーを初期化しない。

例:

```text
詩テキストの読み込みに失敗しました。
3行目の時刻マーカー形式が不正です。
```

## 11. Deno開発仕様

### 11.1 `deno.json`

例:

```json
{
  "tasks": {
    "check": "deno check src/main.ts",
    "test": "deno test",
    "lint": "deno lint",
    "fmt": "deno fmt",
    "build": "deno bundle src/main.ts --output dist/app.js"
  }
}
```

### 11.2 テスト

Denoのテスト機能を用いる。

対象:

- 時刻マーカーのパース
- 正常系の `PoemLine[]` 生成
- 不正形式の検出
- 時刻昇順チェック
- 空行処理
- JSON出力の互換性

テスト例:

```ts
Deno.test("parse poem lines", () => {
  const source = `
[00:00.000] 春の夜に
[00:04.200] 静かに雨が降る
`;

  const lines = parsePoem(source);

  assertEquals(lines, [
    { id: "line-1", time: 0, text: "春の夜に" },
    { id: "line-2", time: 4.2, text: "静かに雨が降る" },
  ]);
});
```

## 12. Ruby / ruby.wasm移行仕様

### 12.1 移行対象

Rubyへ移行する対象は以下に限定する。

- `parser.ts` 相当の処理
- 必要に応じたフォーマット検証
- JSON生成

以下は移行しない。

- 音声制御
- DOM生成
- スクロール制御
- UIイベント処理
- CSS制御

### 12.2 Ruby側インターフェース

Ruby側は文字列を受け取り、JSON文字列を返す。

概念的には以下の形とする。

```ruby
def parse_poem_to_json(source)
  lines = PoemParser.new.parse(source)
  JSON.generate(lines.map(&:to_h))
end
```

### 12.3 TypeScript側インターフェース

TypeScript側ではRubyの返却値を `unknown` として扱い、実行時検証を行う。

```ts
const result = await rubyBridge.parsePoem(source);
assertPoemLines(result);
```

### 12.4 互換性テスト

TS版パーサとRuby版パーサは、同じ入力に対して同じJSONを返す必要がある。

```text
sample.poem
  ↓
TS parser
  ↓
sample.expected.json

sample.poem
  ↓
Ruby parser
  ↓
sample.expected.json
```

## 13. セキュリティ・安全性

### 13.1 HTML挿入

- 詩本文は `innerHTML` ではなく `textContent` で挿入する。
- Ruby側でHTML文字列を生成する設計は初期仕様では採用しない。
- ユーザーが入力したテキストをHTMLとして解釈しない。

### 13.2 ファイル読み込み

- 初期仕様では同梱された詩テキストと音声ファイルのみを読み込む。
- 任意ファイルアップロード対応は将来拡張とする。

## 14. スタンドアローン配布仕様

### 14.1 配布物

初期配布物は以下とする。

```text
dist/
  index.html
  app.css
  app.js
  poems/
    sample.poem
    sample.mp3
```

### 14.2 実行方法

基本的には静的Webサーバー上で実行する。

ローカル開発時は以下のように起動する。

```bash
deno task serve
```

または任意の静的ファイルサーバーを使用する。

### 14.3 完全オフライン対応

将来的にPWA化する場合は以下を追加する。

```text
manifest.json
service-worker.js
```

対象ファイルをキャッシュし、ネットワークなしでも動作できるようにする。

## 15. 非目標

初期仕様では以下を対象外とする。

- 文字単位の同期
- カラオケ的な逐字ハイライト
- 複数音声トラック対応
- 複数詩作品のライブラリ管理
- 編集UI
- ファイルアップロード
- サーバーサイド保存
- 認証
- ルビ・傍点・注釈などの高度な組版
- WebVTT完全互換
- 全処理のWasm化

## 16. 将来拡張

将来的には以下を検討する。

- 連単位同期
- ルビ対応
- 傍点対応
- 注釈表示
- WebVTTエクスポート
- WebVTTインポート
- PWA化
- 複数作品切り替え
- テーマ切り替え
- 行送り速度の調整
- 手動スクロール中の自動スクロール一時停止
- 音声波形表示
- 同期マーカー編集UI
- ruby.wasmによる本番パース
- Ruby製フォーマット検証CLI

## 17. 初期実装の優先順位

### Phase 1: TypeScriptのみでのプロトタイプ

- `PoemLine` 型定義
- `parsePoem()` 実装
- `renderPoem()` 実装
- `PoemPlayer` 実装
- 縦書きCSS
- サンプル音声との同期確認

### Phase 2: Deno開発ツール整備

- `deno test`
- `deno lint`
- `deno fmt`
- `validate_poem.ts`
- JSONスナップショットテスト

### Phase 3: 表示体験の調整

- スクロール挙動調整
- ハイライト表現調整
- フォントサイズ・行間調整
- 縦書き時の表示崩れ確認

### Phase 4: Rubyパーサ移植

- `poem_parser.rb` 実装
- TS版と同一JSONを返すことを確認
- Ruby版テスト追加

### Phase 5: ruby.wasm統合

- ruby.wasm読み込み
- Rubyパーサ実行
- TypeScript側で返却JSONを検証
- 本番ページでTSパーサからRubyパーサへ切り替え

## 18. 基本方針の要約

このアプリでは、ブラウザAPIに近い処理はTypeScriptで実装し、詩テキストの解釈に関わる処理だけを将来的にRuby / ruby.wasmへ移行する。

```text
TypeScript:
  ブラウザアプリとしての動作を担当する

Ruby / ruby.wasm:
  詩フォーマットの解釈を担当する
```

この分担により、ブラウザアプリとしての実装を単純に保ちながら、Rubyによる詩フォーマット処理を後から導入できる構成とする。
