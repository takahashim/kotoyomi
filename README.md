# Kotoyomi

縦書きで詩本文を表示し、朗読音声と同期して現在の連をハイライトするスタンドアローンなWebプレイヤー。

詩テキストは [WebVTT](https://developer.mozilla.org/ja/docs/Web/API/WebVTT_API)
を採用し、ブラウザ標準の `<track kind="metadata">`
でロード・パース・同期する。自前のパーサ／プレイヤーループは持たない。

詳細仕様は [`spec.md`](./spec.md) を参照。

## 要件

- [Deno](https://deno.com/) 2.x

## 開発タスク

```bash
deno task check     # 型チェック
deno task lint      # Lint
deno task fmt       # フォーマット
deno task serve     # ローカルWebサーバー起動 (デフォルト http://localhost:8000/)
deno task build     # src/main.ts を dist/app.js にバンドル
```

## ローカルでの動作確認

1. `deno task build` でブラウザ用のJSをバンドル。
2. `deno task serve` を実行し、ブラウザで `http://localhost:8000/` を開く。
3. `<audio>` の再生ボタンを押すと、現在の連が中央でハイライトされます。

サンプル朗読音声 (`poems/sample.mp3`) と WebVTT 字幕 (`poems/sample.vtt`) は同梱されています。

## 配布物

`deno task build` で生成した `dist/app.js` と、ルートの `index.html` / `app.css` / `poems/`
を任意の静的Webサーバーに配置すれば動作します。

## 詩テキスト形式

[WebVTT](https://www.w3.org/TR/webvtt1/) 準拠。各 cue が 1 つの連に対応する。cue 識別子を付けると
DOM の `id` として再利用される。

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

cue 本文の各行は `<p class="stanza-line">` として `<div class="stanza">` 内に配置され、CSS
の縦書き設定によって右から左へ並ぶ。
