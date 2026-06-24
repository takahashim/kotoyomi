# Kotoyomi (ことよみ)

Markdown で書いたスライドを表示するスタンドアローンな Web スライドビューアです。
音声と同期して読み上げ箇所をハイライトするプレイヤーをスライドの一機能として搭載しているのが特徴です。

- スライドはMarkdownファイルで書く。
- スライド内に ` ```vtt ` コードブロックを置くと、そのページで音声と同期してテキストを表示する。
  表示テキストは [WebVTT](https://developer.mozilla.org/ja/docs/Web/API/WebVTT_API) の cue から生成され、
  `<audio>` の再生に合わせて現在の段落(連)がフェードインしながらハイライトされる。
- ビューア本体は [Lilac](https://github.com/takahashim/lilac)(mruby-wasm 製のフロントエンドフレームワーク)の
  `Lilac::Component`で実装されている。JSはLilacランタイムの起動だけを担う。

Lilacランタイム(`vendor/lilac/lilac.wasm`、約 0.9MB)はリポジトリに同梱しているのでオフライン環境でも使用できます。

## create a new project (kotoyomi new)

CLIで作業用ディレクトリを用意できます。

```bash
kotoyomi new mydeck     # 雛形を生成
cd mydeck
kotoyomi serve          # 配信 + src/deck.md 監視 → http://127.0.0.1:8000/
```

生成物は原稿用の`src/`と配信用の`public/`に分かれます。

```
mydeck/
  src/
    deck.md            ← スライド原稿(Markdown)
    assets/            ← 画像・音声を置く(参照は assets/xxx)
  public/              ← 配信物
    index.html  app.css  src/  lib/  vendor/lilac/  viewer/{index,presenter,print}.html
    viewer/slides.json ← 原稿を変換したJSONファイル
    viewer/assets/     ← src/assets/ から同期される
```

- `kotoyomi serve` … `public/` を配信しつつ `src/deck.md` を監視。原稿を保存すると再ビルドし、
  開いているビューアがその場で再描画する(SSE で再ビルド時のみ通知。ポーリングしないので
  通常閲覧では毎秒アクセスは出ない)。
- `kotoyomi build` … 単発ビルド。`src/deck.md` → `public/viewer/slides.json`(+ `src/assets/` を `public/viewer/assets/` へ同期)。
- `kotoyomi upgrade` … kotoyomi を更新したあと、`public/` の同梱ランタイム(app.css / src / lib /
  vendor/lilac / viewer/*.html)を最新版へ入れ替える。`src/` と build 生成物は保持。
- 公開は `public/` をそのままホスティング可能。

> このリポジトリでは `bundle install` 後 `bundle exec kotoyomi …` で実行できます(gemspec 同梱)。
> どこからでも `kotoyomi` だけで叩けるようにするには、ローカルで `rake install`(または gem 公開後に
> `gem install kotoyomi`)で global インストールしてください。

## 仕組み

```
src/deck.md ──(ビルド時: kotoyomi build)──▶ public/viewer/slides.json + public/viewer/assets/
                                                          │
                                              (実行時: kotoyomi Lilac ビューア)
   SlideDeck ─ data-each で現在スライドだけ mount ─ Slide
       ├ 通常スライド: data-unsafe-html で Markdown 本文を表示
       └ プレイヤースライド: VTT を Blob URL 化して <track> に流し、cue→連を音声同期
```

| 層 | 役割 |
| --- | --- |
| Markdown + ` ```vtt ` | スライド本文 + 音声同期データ(作者が書く) |
| ビルド CLI(MRI・`cli/`) | Markdown → `slides.json`(構造 + 各スライド HTML + プレイヤー設定) |
| ブラウザ (TextTrack API) | VTT のパースと音声同期 |
| Ruby (Lilac::Component, 実行時) | デッキ/ナビ/スライド/プレイヤー・状態 (signal) |
| JS | `lilac.wasm` を boot して `Lilac.start` するだけ |

契約は `slides.json` だけ。ビルド CLI(MRI)とビューア(mruby)は JSON の受け渡しのみです。

## ローカルでの動作確認

ビルド CLI(`cli/` の `Kotoyomi::CLI`)が Markdown 解析に [red_quilt](https://github.com/takahashim/red_quilt) を使うので、隣に red_quilt を clone しておく(sibling 参照、lilac と同じ規約)。

`examples/` はこのリポジトリ同梱の **kotoyomi サンプルプロジェクト**(`src/deck.md` +
生成物 `public/`)です。`make build` / `make serve` はそれぞれ `kotoyomi build` /
`kotoyomi serve` を `examples` に対して実行します(別プロジェクトを対象にするなら
`make serve PROJECT=path/to/proj`)。

```bash
bundle install         # 初回のみ
make serve             # examples を kotoyomi serve: 配信 + 監視 + 自動リロード
```

ブラウザで `http://localhost:8000/viewer/` を開くとデモデッキが動きます。
←/→/Space でスライド送り、`n` で発表者ノートの開閉(テーマは frontmatter で指定)。
プレイヤースライドは `<audio>` の再生で連がハイライトされます。

`make serve` 一つで配信 + `src/deck.md` の監視 + 自動リロード(SSE)まで担うので、
原稿を保存するたびにビューアがその場で再描画します(ページ全体のリロードなし・wasm
再起動なし・表示中のスライド位置やテーマは維持)。単発ビルドだけなら `make build`。

`examples/public/` は雛形ランタイム + ビルド成果物で、生成物なので gitignore 済み
(初回や clone 直後は `make build`/`make serve` が自動展開します)。

## デッキを書く

Markdown を 1 ファイルで書きます。スライド区切りは `---`、スピーカーノートは `> [speaker]`。
音声同期プレイヤーにしたいスライドには ` ```vtt audio="..." ` コードブロックを置きます。

````markdown
# 桜

```vtt audio="assets/sakura.mp3"
WEBVTT

stanza-1
00:00.000 --> 00:00.500
あさ

stanza-2
00:00.500 --> 00:02.800
光がまだ冷たいうちに
```

---

# おわり

通常のスライドは普通の Markdown で書く。
````

- ` ```vtt ` ブロックの中身は素の WebVTT(タイミング + 本文)として書ける。別 .vtt ファイルは不要。
- フェンスの `audio="..."` は音声ファイルのパス。素材は `src/assets/` に置き `assets/xxx` で参照する(ビルド時に `public/viewer/assets/` へ同期。上の例なら `src/assets/sakura.mp3`)。
- ` ```vtt ` ブロックはコードとしては表示されず、プレイヤー設定として抽出される。

### レイアウト(表紙・章扉・分割)

スライド先頭にブロッククォートのマーカーを置くとレイアウトが変わります(マーカー行は本文に出ません)。

| マーカー | レイアウト |
| --- | --- |
| `> [cover]` | 表紙(大タイトル中央) |
| `> [section]` | 章扉(中央寄せの大見出し) |
| `> [subsection]` | 小扉(section と同じ書式・配色だけ別) |
| `> [layout: two-column]` | 左右 2 分割 |
| `> [layout: three-column]` | 3 分割 |

分割レイアウトでは `> [column]`(別名 `> [split]`)で領域を区切ります(2 分割なら 1 回、3 分割なら 2 回)。

````markdown
> [cover]

# ことよみ
#### 音声と同期して読むスライドビューア

---
> [section]

# 第一章 つくり

---
> [layout: two-column]

## 左カラム
左の内容

> [column]

## 右カラム
右の内容
````

### 発表者ノート

`> [speaker]` ブロックがそのスライドのノートになります。発表中に **`n` キー**で表示/非表示を切り替えられます
(投影中は隠したまま手元だけで読む運用)。

書いたら `make build`(対象は `examples`。別プロジェクトは `make build PROJECT=path/to/proj`)。
`<proj>/public/viewer/slides.json` が再生成されます(`make serve` 中なら保存で自動反映)。

## PDF 出力(配布資料)

```bash
make pdf            # → kotoyomi.pdf(別名は make pdf PDF=foo.pdf)
```

`viewer/print.html`(全スライドを 1 ページずつ並べた印刷ビュー)をヘッドレス Chromeで
印刷して PDF にします(`bin/pdf.sh`)。1 スライド = 1 ページ、テーマの背景色も保持します。

## テーマ(配色)

配色テーマは Markdown 先頭の frontmatter で指定します(画面での切り替え UI はありません)。

```markdown
---
theme: dark
---
> [cover]
# タイトル
```

| テーマ | 用途 |
| --- | --- |
| `default`(既定) | 太いゴシック見出し + 強いアクセント。力強いプレゼン向き |
| `minimal` | 白背景 + サンセリフ。明るい部屋・会議室向き |
| `dark` | 暗い背景 + 明るい文字。暗い会場・プロジェクタ投影向き |

frontmatter を省略すると `default`。指定は投影・発表者・PDF すべてに効きます。

## 発表者ビュー(2 画面)

投影用(`viewer/`)と発表者用(`viewer/presenter.html`)を別ウィンドウで開くと、
スライド送りが同期します。発表者ビューには 現在スライド + 続くページ(既定 3 枚)+
発表者ノートが出ます(投影側には出ません)。

- 投影をプロジェクタ画面で全画面、発表者ビューを手元のノート PC 画面で開く、が典型。
- どちらのウィンドウで送っても、←/→/Space で双方が同じページに揃います。
- 続くページの先読み数は `lib/deck.rb` の `PresenterDeck::PREVIEW_COUNT`。

同期は BroadcastChannel(`kotoyomi-sync`)で、サーバ不要・同一オリジンで動きます。
(ただし 同じブラウザの別ウィンドウ間のみ)

## 公開

`kotoyomi build` 済みの `public/` をそのまま静的ホスティングに置くだけで公開できます。

## アーキテクチャ

- `lib/*.rb`: Lilac ビューア本体(mruby 上で実行)
- `src/ruby_runtime.js`: `lilac.wasm` を boot し `lib/*.rb` を eval して `Lilac.start` するJS
- `vendor/lilac/`: [Lilac](https://github.com/takahashim/lilac) の :full ランタイム
- `cli/`: ビルド時 CLI
- `viewer/`: ビューアの HTML(`index.html` / `presenter.html` / `print.html`)。`kotoyomi new`/`upgrade`
  がプロジェクトの `public/viewer/` へコピーする雛形(`index.html` / `app.css` / `src` / `lib` /
  `vendor/lilac` と並ぶランタイムの一部)
- `examples/`: 同梱のサンプルプロジェクト(`src/deck.md` + 素材、生成物 `public/` は gitignore)

## 検証

```bash
make test     # rspec(ビルド CLI = cli/)+ minitest(Slides.parse)の Ruby テスト
make smoke    # デッキ/ナビ/プレイヤー/unmount を検証(Ruby のみ、Node/npm 不要)
```
