# Kotoyomi

縦書きで詩本文を表示し、朗読音声と同期して現在行をハイライト・スクロールするスタンドアローンなWebプレイヤー。

詳細仕様は [`spec.md`](./spec.md) を参照。

## 要件

- [Deno](https://deno.com/) 2.x

## 開発タスク

```bash
deno task check     # 型チェック
deno task test      # テスト実行
deno task lint      # Lint
deno task fmt       # フォーマット
deno task serve     # ローカルWebサーバー起動 (デフォルト http://localhost:8000/)
deno task build     # src/main.ts を dist/app.js にバンドル
```

## ローカルでの動作確認

1. `deno task build` でブラウザ用のJSをバンドル。
2. `deno task serve` を実行し、ブラウザで `http://localhost:8000/` を開く。
3. `<audio>` の再生ボタンを押すと、詩の現在行がハイライトされ縦書き表示がスクロールします。

サンプル朗読音声 (`poems/sample.mp3`) と詩テキスト (`poems/sample.poem`) は同梱されています。

## 配布物

`deno task build` で生成した `dist/app.js` と、ルートの `index.html` / `app.css` / `poems/`
を任意の静的Webサーバーに配置すれば動作します。

## CLI ツール

```bash
deno run --allow-read tools/validate_poem.ts poems/sample.poem
```

詩テキストをパースして JSON を標準出力に書き出します。形式不正の場合は exit code 1。

## 詩テキスト形式

```
[mm:ss.mmm] 本文
```

例:

```
[00:00.000] 春の夜に
[00:04.200] 静かに雨が降る
```

詳細は [`spec.md`](./spec.md) §5 を参照。
