# ruby.wasm から mruby.wasm への移行: メリット・デメリット

kotoyomi は当初 [ruby.wasm](https://github.com/ruby/ruby.wasm) (CRuby を WASM
にビルドしたもの) + `js` gem で動かしていたが、Phase 2 (`feat/mruby-runtime`
ブランチ) で **mruby + 自前 mrbgem `mruby-js-bridge`** に切り替えた。
本ドキュメントはその選択の trade-off を整理する。

> ruby.wasm 自体は素晴らしいプロジェクト。「kotoyomi のような小規模な
> プレイヤー」 という用途では mruby のほうが噛み合う、というだけの話で、
> 一般的に「ruby.wasm より mruby が優れている」という主張ではない。

## 結論先出し

| 観点 | 推奨 |
|---|---|
| 中〜大規模 Ruby アプリを WASM で動かしたい | **ruby.wasm** |
| 小さく速く起動したい、組込み志向、ランタイムを掌握したい | **mruby** |
| picoruby (microcontroller) への将来移行を想定 | **mruby (経由 picoruby)** |
| Ruby 文法と stdlib を完全互換でほしい | **ruby.wasm** |

kotoyomi は「縦書きプレイヤー」という小規模 UI で、stdlib も少ししか
使わず、CDN 依存をなくしたいという要望 (offline 利用、自分の VPS 等での
ホスティング) があったので mruby が刺さった。

## メリット (mruby に切り替えた良かった点)

### 1. バイナリサイズ

| ランタイム | 非圧縮 | gzip | brotli (実 CDN) |
|---|---|---|---|
| ruby.wasm (`ruby+stdlib.wasm`) | ~17.2 MB | ~4.4 MB | ~3 MB |
| **mruby + mruby-js-bridge** | **~3.9 MB** | **~1.1 MB** | **~0.8 MB** |

実効転送量で約 **4 倍小さい**。kotoyomi は WebVTT + 数十 KB の本文しか
扱わないので、ランタイム自体が支配的サイズだった。

### 2. 起動速度

ruby.wasm は CDN 取得 + WASM compile + Asyncify 初期化 + Ruby require 等で
数秒オーダー。mruby は同程度ハードウェアで **1 秒以内** に boot 可能。
kotoyomi のような「audio タグの隣に Ruby が配置される」UI ではこの差は
体感に直結する。

### 3. CDN 依存を解消できる

ruby.wasm 構成では `cdn.jsdelivr.net/npm/@ruby/...` 経由で wasm を取得して
いた。これは:

- jsdelivr が落ちると kotoyomi が動かない
- offline 利用時に動かない (PWA 化したくても起動でコケる)
- バージョン (semver) ピン依存

mruby 版は **`vendor/mruby-js-bridge/mruby.wasm` を self-host** する。
`vendor/` 一式をデプロイすれば外部依存ゼロ。GitHub Pages にも 4MB の
wasm を含めて配布できる。

### 4. 依存関係をフルコントロールできる

ruby.wasm は CRuby + 標準ライブラリ全部 + ruby.wasm の internals が
パッケージ化されたバイナリで、不要な部分を削れない。

mruby は mrbgems の組合せが build 時に決まる:

- `default-no-stdio` から `mruby-regexp` を除外
- `mruby-method` `mruby-fiber` `mruby-compiler` を必要分だけ追加
- 自前 gem (`mruby-js-bridge`) を直接 build に組み込む

これで「kotoyomi が必要としない gem は wasm に入れない」が達成できる。

### 5. C 拡張を書きやすい (interop の主導権)

`js` gem は ruby.wasm 側がメンテする「外部 API」だが、mruby-js-bridge は
**自前実装** なので:

- `JSBridge::Error#js_value` (JS Error 完全保持) のような独自機能を即追加可
- callback テーブルの release API などのメモリ管理を自分で設計できる
- bug を踏んでも自分で直せる (実際 Phase 2 中に何度も踏んだ)

### 6. 将来の picoruby 移行パス

picoruby (mruby/c ベース) は microcontroller (Pi Pico、ESP32) で動く Ruby。
mruby と API が近いので、kotoyomi が将来 IoT デバイス上で動く想定がある
場合、mruby 経由の方が picoruby への移植コストが低い。

## デメリット (失ったもの・移行時に踏んだ問題)

### 1. Ruby 互換性は subset

mruby は CRuby のサブセット。kotoyomi の lib コードは元々シンプルだったので
ほぼそのまま動いたが、以下は移植時に書き換えが必要だった:

- `defined?(JS)` 形式の存在チェック (mruby の `defined?` は微妙な挙動差)
- `private_class_method` (mruby-class-ext gem 不在で使えない)
- `String#split` の regexp 引数 (mruby-regexp の bug を踏んで除外)

中規模以上の Ruby アプリを移植するなら互換性 issue が頻繁に出る覚悟が
必要。

### 2. stdlib が薄い

Net::HTTP、CSV、Date、Time、ERB、JSON 等は CRuby 同等版がない or 別 gem
として個別実装が必要。「Ruby らしい便利系」が欠けるので、Web フロント
エンドを mruby で書くと「これも自前か」が多い。kotoyomi は文字列処理が
主体だったので影響は軽微だった。

### 3. await を自前実装する必要があった

ruby.wasm は CRuby + Asyncify で `Promise#await` が透過に動く。mruby に
fiber/Asyncify 機構は標準で無いので、`mruby-js-bridge` は **mruby-fiber 上に
独自に await を実装** した:

- 各 evalRuby 呼び出しを Fiber でラップ
- `Value#await` が Fiber.yield でサスペンド
- Promise の `.then`/`.catch` から `Fiber#resume` する registry 機構

これで実用的に動くが、CRuby のスタックフレーム保持 (Asyncify) と比べると
stack trace が await を跨いで切れるなど細かな違いがある。

### 4. ビルドハードル

ruby.wasm は npm 経由で導入。mruby は wasi-sdk + mruby ソース + 自前
build_config が必要:

```bash
make download        # wasi-sdk 33.0 (~173MB)
make all             # 展開 + mruby ビルド + リンク
```

CI/CD が複雑になる。我々は Phase A の `make dist` で「ビルド済み wasm を
vendor 配置 + コミット」で回避したが、上流 mruby が更新されたら再ビルドして
再コミットというフローになる。

### 5. mruby HEAD の不安定性

今回 `mruby-regexp` の `String#split` が `super` で C 実装に届かない
バグを踏んだ。**Matz 自身が直前に commit した部分** で、テストでも踏まれて
いない経路だった。mruby HEAD は CRuby の minor release 並みには安定して
いない (= リリースタグを使う方が安全)。

### 6. コミュニティ規模

mruby は CRuby と比べて users / contributors / docs / Stack Overflow
回答数すべて圧倒的に少ない。「動かない」を遭遇したときに過去事例を
ググるとほぼヒットしない。エラーメッセージから mruby のソースを直接
読みに行く覚悟が必要。

### 7. WASM 周りの 2 ステップ移植

ruby.wasm は最初から WASM build が公式品質。mruby + WASI は
コミュニティ実装ベースで、setjmp/longjmp の WebAssembly EH proposal、
mruby-io の POSIX header 不足、`__wasm_setjmp_test` の解決などのハマり
ポイントが各所に散らばっている (Phase 1 spike summary に記録済み)。

新規プロジェクトで「Ruby を WASM で」を目指すなら ruby.wasm の方が
**圧倒的にハードルは低い**。

## 数字で見る kotoyomi の場合

| 項目 | ruby.wasm 版 | mruby + mruby-js-bridge 版 |
|---|---|---|
| 配布サイズ (gzip) | ~4.4 MB | **~1.1 MB** |
| 初回ロード時間 (体感) | 3-5 秒 | **1 秒未満** |
| CDN 依存 | あり (jsdelivr) | **なし (self-host)** |
| ランタイム自前メンテ | 不要 (ruby team が管理) | **必要 (mruby HEAD 追従)** |
| 開発時のビルド | npm install のみ | wasi-sdk + mruby cross build |
| Ruby コードの書き換え (lib/*.rb) | — | 4 ファイル中、`require "js"` 削除 + `wait_for_track_load` の heredoc 末尾 `;` 除去のみ |
| 移植開発工数 | — | 累計 1-2 週間 (gem 自体の開発含む) |

## 「やる価値があったか」の自己評価

kotoyomi の目線では **「やる価値があった」**。
理由:

- CDN-free 配布が確実にできる (個人サイトホスティング向き)
- 起動速度の改善が UX に直結
- 自前 gem が「(再利用可能なライブラリ) (`mruby-js-bridge`)」として残る
- Phase 6 で picoruby/microcontroller を視野に入れる柔軟性
- mruby + WASM のハマりどころを記録した (`docs/phase1-spike-summary.md`、
  `docs/phase2-spike-summary.md`) ので、後続プロジェクトの参考になる

ただし **「ruby.wasm の代わりに mruby を選ぶ」を一般化はしない**。中〜
大規模 Ruby アプリを WASM 化したいなら ruby.wasm の方が確実に現実解。
mruby を選ぶのは「小ささ」「自前管理」「picoruby 路線」のいずれかが
強く動機づける場合に限る。
