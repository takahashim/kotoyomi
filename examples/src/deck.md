---
theme: default
---
> [cover]

# ことよみ サンプル

#### 音声と同期して読むスライドビューア

> [speaker]
> 発表者ノートはこう書きます(発表中に `n` キーで開閉)。投影には出ません。

---
> [section]

# つかいかた

---
# Markdown 一本で書く

- スライド区切りは `---`
- 見出し・リスト・強調など普通の Markdown
- スピーカーノートは `> [speaker]`
- 編集して保存すると(`make serve` 中は)その場で反映

---
# 編集と配信

- `make serve` … `examples` を配信 + 監視 + 自動リロード
- `make build` … 単発ビルド(`public/viewer/slides.json` を再生成)
- 公開は `public/` をそのまま静的ホスティングに置くだけ

---
> [section]

# レイアウト

---
> [subsection]

# 小扉(subsection)

`> [cover]` / `> [section]` / `> [subsection]` で扉ページになります。

---
> [layout: two-column]

# 2 カラム

> [column]

## 左

- `> [layout: two-column]` を先頭に
- `> [column]` で区切る

> [column]

## 右

- 配置は CSS が `data-layout` で決める
- レイアウト追加は CSS だけで済む

---
> [layout: three-column]

# 3 カラム

> [column]

## 一

`> [layout: three-column]` は
`> [column]` を 2 回。

> [column]

## 二

各カラムは普通の Markdown。

> [column]

## 三

画像やリストも置けます。

---
# 画像

![サンプル画像](assets/700x500.png)

素材は `src/assets/` に置き、`assets/xxx` で参照します
(ビルド時に `public/viewer/assets/` へ同期)。

---
# 音声同期プレイヤー

` ```vtt audio="..." ` ブロックを置くとプレイヤースライドになります。
`<audio>` の再生に合わせて現在の連(stanza)がハイライトされます。

---

```vtt audio="assets/sample.mp3"
WEBVTT

00:00.000 --> 00:02.252
おとに あわせて
ことばが ながれる

00:02.252 --> 00:04.071
よむ ところが
ひかって すすむ

00:04.071 --> 00:05.657
これが ことよみ です
```

---
> [section]

# おわり

---
# まとめ

- Markdown 一本でスライド + 音声同期プレイヤー
- レイアウトは扉 / 分割を `> [...]` マーカーで
- `make serve` で書きながら確認できる

ことよみ — 音声と同期して読むスライドビューア。
