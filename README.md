# ことよみ (Kotoyomi)

Markdown で書いたスライドを表示するスタンドアローンな Web スライドビューアです。
音声と同期して読み上げ箇所をハイライトするプレイヤーをスライドの一機能として搭載しているのが特徴です。

- スライドは Markdown 1 ファイルで書く(同梱のビルド CLI `cli/`(Kotoyomi::CLI)がビルド時に変換)。
- スライド内に ` ```vtt ` コードブロックを置くと、そのスライドが**音声同期プレイヤー**になる。
  表示テキストは [WebVTT](https://developer.mozilla.org/ja/docs/Web/API/WebVTT_API) の cue から生成され、
  `<audio>` の再生に合わせて現在の連がフェードインしながらハイライトされる。
- ビューア本体は [Lilac](https://github.com/takahashim/lilac)(mruby-wasm 製のフロントエンドフレームワーク)の
  `Lilac::Component`。デッキ・ナビ・スライド・プレイヤーはすべて Lilac コンポーネントで、
  状態は signal、表示は `data-each` / `data-class` / `data-text` で宣言的に書く。JS は Lilac ランタイムの
  起動だけを担う最小のブートシム。

Lilac ランタイム(`vendor/lilac/lilac.wasm`、約 0.9MB)はリポジトリに同梱しているので CDN 依存はゼロ
(オフライン・ネットワーク不通の環境でもそのまま動く)。

## プロジェクトを作る(kotoyomi new)

clone せずに、CLI で作業ディレクトリを作れます。

```bash
kotoyomi new mydeck     # 雛形を生成
cd mydeck
kotoyomi serve          # 配信 + src/deck.md 監視 → http://127.0.0.1:8000/
```

生成物は **作者が書く `src/`** と **配信する静的サイト `public/`** に分かれます:

```
mydeck/
  src/
    deck.md            ← スライドを書く(frontmatter で theme: 等)
    assets/            ← 画像・音声を置く(参照は assets/xxx)
  public/              ← 配信物(そのまま GitHub Pages 等へ)
    index.html  app.css  src/  lib/  vendor/lilac/  viewer/{index,presenter,print}.html
    viewer/slides.json ← kotoyomi build の生成物
    viewer/assets/     ← src/assets/ から同期される
```

- `kotoyomi serve` … `public/` を配信(wsv)しつつ `src/deck.md` を監視。編集すると再ビルドし、
  ビューア(localhost のとき)が `slides.json` の変化を拾ってその場で再描画する。`--no-watch` で
  監視を止めて配信のみ。
- `kotoyomi build` … 単発ビルド。`src/deck.md` → `public/viewer/slides.json`(+ `src/assets/` を `public/viewer/assets/` へ同期)。
- 公開は `public/` をそのままホスティングに置くだけ(ランタイム不要)。

> 現状この CLI はこのリポジトリの `bundle exec exe/kotoyomi …` で動きます。`gem install kotoyomi`
> で global コマンド化(= clone も bundle も不要)するには gem 化が次のステップです。

## 仕組み

```
deck.md ──(ビルド時: kotoyomi --format json)──▶ viewer/slides.json + viewer/media/
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

```bash
bundle install         # 初回のみ
make build             # examples/deck.md → viewer/slides.json
make serve             # wsv で 127.0.0.1:8000 配信
```

ブラウザで `http://localhost:8000/viewer/` を開くとデモデッキが動きます。
←/→/Space でスライド送り、`n` で発表者ノートの開閉(テーマは frontmatter で指定)。
プレイヤースライドは `<audio>` の再生で連がハイライトされます。

### ライブリロード(編集→自動反映)

別ターミナルで `make watch` を起動すると、`deck.md` を保存するたびにビルド CLI
(`kotoyomi --watch -o`)が `viewer/slides.json` を再生成します。ビューアは
**localhost のときだけ** slides.json の変化を検知し、ページ全体をリロードせず
その場で再描画します(wasm 再起動なし・表示中のスライド位置やテーマは維持)。

```bash
make serve     # ターミナル1: 配信
make watch     # ターミナル2: deck.md を監視して slides.json を再生成
```

仕組み: `make watch`(ビルド CLI の mtime 監視)→ `viewer/slides.json` 更新 →
`src/hotreload.js`(localhost のみポーリング)が `kotoyomi:slides` イベントを発火 →
`SlideDeck` / `PresenterDeck` が `@slides` を差し替え。本番(GitHub Pages 等)では
ポーリングしません。

## デッキを書く

Markdown を 1 ファイルで書きます。スライド区切りは `---`、スピーカーノートは `> [speaker]`。
**音声同期プレイヤー**にしたいスライドには ` ```vtt audio="..." ` コードブロックを置きます。

````markdown
# 桜

```vtt audio="media/sakura.mp3"
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
- フェンスの `audio="..."` は音声ファイルのパス。`viewer/` からの相対パスで解決される(上の例なら `viewer/media/sakura.mp3` を置く)。
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

レイアウトの仕組みは「ビルド CLI が領域(regions)に分けて JSON 化 → ビューアが `data-layout` で配置」。
**新しいレイアウトの追加は基本 `app.css` に `.slide-body[data-layout="…"]` を 1 ブロック足すだけ**で、
ビルド CLI / Ruby は触りません。

### 発表者ノート

`> [speaker]` ブロックがそのスライドのノートになります。発表中に **`n` キー**で表示/非表示を切り替えられます
(投影中は隠したまま手元だけで読む運用)。

書いたら `make build`(デフォルトは `examples/deck.md`。別ファイルは `make build DECK=path/to/deck.md`)。
`viewer/slides.json` が再生成されます。

> CI にはビルド環境(red_quilt)が無い前提なので、`viewer/slides.json` と `viewer/media/` はコミットして配信します。
> デッキを編集したら手元で `make build` してからコミットしてください。

## 本文テキスト形式(WebVTT)

[WebVTT](https://www.w3.org/TR/webvtt1/) 準拠。各 cue が 1 つの連(stanza)に対応します。

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

cue 本文の各行は `<p class="stanza-line">` として `<div class="stanza">` 内に配置され、
CSS の縦書き設定で右から左へ並びます。再生位置に対応する連だけに `active` class が付きます。

## PDF 出力(配布資料)

```bash
make pdf            # → kotoyomi.pdf(別名は make pdf PDF=foo.pdf)
```

`viewer/print.html`(全スライドを 1 ページずつ並べた印刷ビュー)を**ヘッドレス Chrome**で
印刷して PDF にします(`bin/pdf.sh`)。1 スライド = 1 ページ、テーマの背景色も保持します。

- 要 **Google Chrome**(既定パスは macOS の `/Applications/Google Chrome.app/...`。
  別の場所/別ブラウザは `CHROME=/path/to/chrome make pdf`)。
- プレイヤー(詩)スライドは PDF では**再生操作ボタンと進捗インジケータを出さず**、最初の連だけを
  縦書きで載せます。
- テーマは frontmatter の `theme:` が PDF にも反映されます(背景色も保持)。
- 各スライドをブラウザで個別に印刷したいときは、`viewer/` を開いて Cmd-P → PDF 保存でも
  「現在のスライド 1 枚」を同じ印刷スタイルで出せます。

## テーマ(配色)

配色テーマは **Markdown 先頭の frontmatter** で指定します(画面での切り替え UI はありません)。

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

実装: ビルド CLI が frontmatter を `slides.json` の `metadata` に載せ、deck 起動時に
`Kotoyomi::Theme` が `<html data-theme="…">` を適用するだけ(`app.css` の CSS 変数が一括で
切り替わる)。テーマを足すには `app.css` に `[data-theme="…"]` ブロックを 1 つ追加します。

## 発表者ビュー(2 画面)

投影用(`viewer/`)と発表者用(`viewer/presenter.html`)を**別ウィンドウ**で開くと、
スライド送りが同期します。発表者ビューには **現在スライド + 続くページ(既定 3 枚)+
発表者ノート**が出ます(投影側には出ません)。

- 投影をプロジェクタ画面で全画面、発表者ビューを手元のノート PC 画面で開く、が典型。
- どちらのウィンドウで送っても、←/→/Space で双方が同じページに揃います。
- 続くページの先読み数は `lib/deck.rb` の `PresenterDeck::PREVIEW_COUNT`。

詩(音声同期)スライドでは、発表者ビューに **再生 / 止める / 最初に戻る + 進捗インジケータ**が出ます。
音は投影側だけで鳴り、発表者ビューのボタンは投影側へコマンドを送る「リモコン」、インジケータは
投影側から届く再生位置を表示します。

音声があるデッキでは、投影ビューの**最初のページに「🔊 クリックして再生を有効化」ボタン**が出ます。
発表者ビューからの「再生」は投影ウィンドウでの操作ではないため、ブラウザの自動再生ポリシーにより
投影ウィンドウが未操作だと音が鳴りません。発表前に投影ウィンドウでこのボタンを一度クリックすれば
解錠され、以降は発表者ビューからの再生で鳴ります(ボタンは消えます)。

同期は **BroadcastChannel**(`kotoyomi-sync`)で、サーバ不要・同一オリジンで動きます。
ただし **同じブラウザの別ウィンドウ間だけ**です(Chrome と Firefox のような別アプリ間は
同期しません。それにはサーバ/WebSocket が必要)。BroadcastChannel 非対応環境では同期なしで
単独動作します。

## 公開する

`kotoyomi build` 済みの **`public/` をそのまま静的ホスティングに置くだけ**で公開できます
(Ruby も kotoyomi も実行されない・`slides.json` はコミット運用)。`public/` 配下が完結した
静的サイトです(`index.html` がルート、`viewer/` 以下が本体)。

- **GitHub Pages**: `public/` を配信対象にする。例)`public/` を `docs/` にして「Settings → Pages →
  Deploy from a branch → `/docs`」、または `public/` をアップロードする Actions を自前で用意。
- **その他(Netlify / Cloudflare Pages / S3 等)**: 公開ディレクトリを `public/` に指定すれば OK。

> このリポジトリ自体はツール(`kotoyomi` CLI)とデモのソースで、Pages へ自動デプロイはしません
> (デモ用の GitHub Actions は廃止しました)。公開対象はあなたが `kotoyomi new` で作ったプロジェクトの
> `public/` です。

## アーキテクチャ

- **`lib/*.rb`** — Lilac ビューア本体(mruby 上で実行)
  - `deck.rb` — `SlideDeck`。`slides.json` を取り込み、`data-each` で現在スライドだけ mount。
    ナビ(←/→/Space・ボタン・カウンタ)を Lilac state で管理。index を進めると keyed reconciler が
    前スライドを unmount(プレイヤーの停止/解放はその cleanup で完結)。
  - `slide.rb` — `Slide`。props(index/html/audio/vtt)は item から auto-fill。通常スライドは
    `data-unsafe-html`、プレイヤースライドは Blob URL track をイベント駆動でロードして cue→連を同期。
  - `slides.rb` — `slides.json` を Ruby に取り込む入口。各 deck が `Fetchy.json` で取得し、
    純 Ruby の `Slides.parse`(JS 非依存・単体テスト可)で正規化。
  - `renderer.rb` — WebVTT cue → `data-each` 用データモデルへの純変換。
  - `player.rb` — 再生位置から「光らせるべき連の index」を求める純ロジック。
  - `vtt_track.rb` — VTT 文字列を Blob URL 化して `<track>`/`<audio>` に流す薄い JS 副作用層。
- **`src/ruby_runtime.js`** — `lilac.wasm` を boot し `lib/*.rb` を eval して `Lilac.start` する最小ブートシム。
- **`vendor/lilac/`** — [Lilac](https://github.com/takahashim/lilac) v0.1.0 の同梱物(`lilac.wasm` +
  JS ブリッジ `mruby-wasm-js/`)。<https://takahashim.github.io/lilac/v0.1.0/> と同一レイアウトを self-host し、
  オフラインでも動くようにしている。
- **`cli/`** — ビルド時 CLI `Kotoyomi::CLI`(MRI)。Markdown(+frontmatter)→ `slides.json`。
  red_quilt で解析、partitioner でスライド/領域分割、renderer で JSON/HTML 出力。`exe/kotoyomi` が入口。
  ランタイム(`lib/`, mruby/wasm)とは別プロセス・別名前空間で、配信物には含めない。
- **`viewer/`** — デッキの `index.html` + ビルド成果物 `slides.json` + メディア。

## 検証

```bash
make test     # rspec(ビルド CLI = cli/)+ minitest(Slides.parse)の Ruby テスト
make smoke    # happy-dom 上でデッキ/ナビ/プレイヤー/unmount を検証 (npm run smoke)
```

`make smoke` は実 TextTrack を持たない happy-dom 上で cue をスタブして検証します。実際の Blob track での
音声同期はブラウザで確認します(`make serve` → `/viewer/`)。

ランタイムを ruby.wasm ではなく mruby/Lilac に切り替えた経緯は
[`docs/runtime-tradeoffs.md`](./docs/runtime-tradeoffs.md) を参照。Lilac 側に投げた改善要望は
[`TODO_lilac.md`](./TODO_lilac.md)。
