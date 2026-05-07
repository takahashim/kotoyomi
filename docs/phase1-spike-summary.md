# Phase 1 Spike サマリ — 自前 mrbgem JS ブリッジの実現性検証

**期間**: 2026-05-07 1 日 (約数時間)
**ブランチ**: `spike/mruby-bridge`
**結果**: ✅ 成功

## 1. 目的と成功条件

「ruby.wasm の `js` gem や `mruby-js` などの既存実装に依存せず、kotoyomi 専用に C で自前の mrbgem を書いて mruby を WebAssembly で動かす」ことが現実的に可能か、最小プロトタイプで検証する。

成功条件 (3 つ全て満たすこと):

1. mruby を wasi-sdk でビルドした WASM がブラウザで instantiate できる
2. ブラウザコンソールに mruby の `puts` 出力が出る
3. Ruby から自前関数 `JSBridge.eval(src)` 経由で JS が実行され、ブラウザタブのタイトルが変わる

3 つ全て達成。

## 2. 達成した最終構成

### ツールチェーン

- **wasi-sdk 33.0** (arm64-macos リリース、ダウンロード ~173MB → 展開済み ~700MB)
- **clang `--target=wasm32-wasip1`** (wasi-sdk 同梱の LLVM 22.1.0)
- **mruby** master HEAD (2026-05 時点、shallow clone)

### コンパイル/リンクフラグ

- `-mllvm -wasm-enable-sjlj` — setjmp/longjmp を WebAssembly Exception Handling 提案に乗せる
- `-lsetjmp` — libsetjmp.a (wasi-sysroot 同梱) で `__wasm_setjmp/longjmp/setjmp_test` の実体を解決
- `-DMRB_NO_BOXING -DMRB_UTF8_STRING` — mruby のオプション定義 (libmruby.a と main.c で揃える必要あり)
- `-Wl,--allow-undefined` — POSIX 関数を未解決のまま wasm imports 化
- `-isystem stubs -include stubs/wasi-shims.h` — POSIX ヘッダ不足を補うスタブ強制注入

### 採用した mruby gembox

`default-no-stdio` をベースに、最小限を追加:

- `mruby-compiler` (Ruby ソースのランタイム解釈用、`mrb_load_string` の実体)
- `mruby-io` (`Kernel#puts` 提供のため、`io_puts` が `puts` の実体)

`stdlib-io` の他の gem (`mruby-socket`, `mruby-dir`, `mruby-env`, `mruby-errno`) は不要なので除外。

### スタブ・shim ファイル

`spike/stubs/`:

- `pwd.h` — 空のスタブ。mruby-io の file.c が include するだけで未使用なので問題なし
- `sys/wait.h` — `WEXITSTATUS` 等のマクロ + `waitpid` 宣言
- `wasi-shims.h` — `dup` `dup2` `waitpid` の宣言、force-include 用

### 最終バイナリサイズ

`mruby.wasm`: **約 4.1MB** (ruby.wasm の 1/4 程度)

### imports 構成 (合計 40 個)

| 種別 | 数 | 取扱 |
|---|---|---|
| `kotoyomi.js_eval` | 1 | 自前実装 |
| `wasi_snapshot_preview1.fd_write` 等 | 12 | 必要分は実装、未使用は ENOTSUP/EBADF 返し |
| `env.mrb_hal_io_*` (24 個) + `dup`, `waitpid` | 26 | JS で no-op stub (-1 返し) |

## 3. 解決した技術課題 (時系列)

### (1) setjmp/longjmp 未対応エラー

**症状**: clang が `setjmp.h` を include した時点で `#error Setjmp/longjmp support requires Exception handling support`

**原因**: wasi-sdk の wasi-libc は setjmp を提供しておらず、WebAssembly EH 提案を有効化しないとビルドできない

**解決**: cflags に `-mllvm -wasm-enable-sjlj` を追加。EH を使った SJLJ コード生成を有効化

### (2) mruby-io が POSIX ヘッダを要求

**症状**: `'pwd.h' file not found`、`'sys/wait.h' file not found`、`'netdb.h' file not found`

**原因**: mruby-io の file.c, io.c は POSIX 環境を前提に書かれているが wasi-sysroot は完全な POSIX を提供しない

**解決**:
- `pwd.h` は include されるだけで symbol 未使用 → 空ファイルで OK
- `sys/wait.h` はマクロ + 関数宣言だけ書いた最小 stub
- `netdb.h` は mruby-socket の依存 → mruby-socket を gembox から外して回避

### (3) `dup` 関数未宣言

**症状**: `error: call to undeclared function 'dup'`

**原因**: wasi-libc の unistd.h が `int dup(int);` を `__wasilibc_unmodified_upstream` ガードで省いている

**解決**: `wasi-shims.h` で `dup` を extern 宣言、`-include` で全 .c に強制注入。シンボル未解決は `--allow-undefined` で imports 化、JS 側で no-op stub

### (4) `mrb_load_string` がリンク時に未解決

**症状**: 初回ビルドで `mrb_load_string` が wasm import になっていた

**原因**: `default-no-stdio` gembox には `mruby-compiler` (パーサ) が含まれていない

**解決**: `conf.gem core: "mruby-compiler"` を build_config に明示追加

### (5) `mrb_value` シグネチャ不一致

**症状**: `wasm-ld: warning: function signature mismatch: mrb_load_string`

**原因**: main.c をコンパイルする時に `MRB_NO_BOXING` 等の定義が無く、libmruby.a 側 (定義あり) と `mrb_value` 構造体のレイアウトが食い違って ABI が変わってしまった

**解決**: main.c のリンク行にも `-DMRB_NO_BOXING -DMRB_UTF8_STRING` を渡す

### (6) `__wasm_setjmp` 等が JS imports に流出

**症状**: 最初は `env.__wasm_setjmp` `__wasm_longjmp` `__c_longjmp` (tag) などが imports として要求され、JS で実装するも setjmp_test が env=0 で呼ばれて escape

**原因**: SJLJ ランタイムは libsetjmp.a に実装されているのに、リンクで指定し忘れていた

**解決**: `-lsetjmp` をリンクフラグに追加。WASI SDK の `wasm32-wasip1/libsetjmp.a` が引き込まれて `__wasm_setjmp/longjmp/setjmp_test` がすべて解決され、imports が消失

### (7) WASI `fd_fdstat_get` 未実装で boot 失敗

**症状**: `WebAssembly.instantiate(): Import #6 "wasi_snapshot_preview1" "fd_fdstat_get": function import requires a callable`

**原因**: adapter.js の WASI imports に書き忘れ

**解決**: 24 byte の fdstat 構造体を 0 で埋めて返す stub を追加

### (8) `puts` 未定義

**症状**: `(unknown):0: undefined method 'puts' for Object (NoMethodError)` が stderr に出るが、stdout には何も出ない

**原因**: `default-no-stdio` には IO 関連の gem が一切無い

**解決**: `mruby-io` を明示追加。これで `Kernel#puts` (実体は io.c の `io_puts`) が定義される

## 4. ハマらなかった/予想より楽だった点

- **WebAssembly EH の SJLJ ランタイム** は wasi-sdk 同梱の libsetjmp.a で完結 (リンクするだけ)。当初の plan では「WebAssembly Exception API (`WebAssembly.Tag` / `WebAssembly.Exception`) を JS で実装する」とまで覚悟していたが、不要だった
- **mruby の WASI ビルドは想像より素直**。`build_config/wasi.rb` を 30 行ほど書いて clang をフックすれば通る
- **fd_write は STDOUT/STDERR を分けるだけで `puts` も `STDERR.puts` も両方流せる**。改行で flush するシンプルな実装で済んだ

## 5. 残課題 (Phase 2 以降)

### 機能面

- **ハンドルの release** — 現在 alloc しっぱなし (連続再生でメモリリーク)。`JS.release(handle)` の C 関数 + JS 側 release を追加
- **`JS::Value` Ruby ラッパークラス** — 整数 handle のままだと使いにくい。`[]/[]=/.call` を持つラッパーを mrblib 側で書く
- **追加 API**: `js_get`, `js_set`, `js_call` を C 側で実装、対応する WASM imports を JS 側で
- **`addEventListener` 等の callback** — Ruby block を JS function として登録するための双方向 marshalling
- **Promise/await の代替** — mruby は fiber 標準で持たないので、callback パスへの書き換えが必要 (`wait_for_track_load` など)

### 性能・配布

- **mrbc 化** — 開発中は runtime eval だが、本番では `.rb` を bytecode コンパイルして `.mrb` で配信した方が起動速度・サイズで有利
- **POSIX/HAL imports の整理** — 現在 30 個近い stub があるが、本来不要な gem を含めなくてよくなれば減らせる
- **vendor 同梱化** — 現在 ruby.wasm は CDN 取得だが、mruby.wasm を vendor 配置すればオフライン化と URL 永続性確保

### 既存 kotoyomi コードとの統合

- `lib/dom.rb` の `Kotoyomi::DOM::Element` の内部実装 (`@node.appendChild` 等) を `JS::Value` API ベースに置換
- `src/ruby_runtime.js` を全面書き換え (DefaultRubyVM → 自前 mruby ローダー)
- 既存テスト (`works/sample/`) の動作確認

## 6. 再現手順

```bash
git switch spike/mruby-bridge
cd spike
make download   # wasi-sdk 33.0 を vendor/ に取得 (~173MB、resumable)
make all        # 展開 → mruby ビルド → main.c とリンク
make serve      # http://localhost:8001/ で開いてコンソール確認
```

成功時の表示:
- ブラウザコンソール: `[mruby] hello from mruby` / `[mruby] got handle: 1`
- タブのタイトル: `spike OK`
- `[stub] mrb_hal_io_init` / `mrb_hal_io_final` の警告 (mruby-io の init/final で呼ばれる、無害)

## 7. 関連ファイル

- `spike/Makefile` — ビルドオーケストレーション
- `spike/main/main.c` — `mrb_load_string` で test script を eval する自前 main
- `spike/build_config/wasi.rb` — mruby を wasi-sdk + clang でビルドする設定 (mruby clone の外に置いて `spike/mruby/` を gitignore できるように)
- `spike/mrbgem/mruby-js-bridge/src/js_bridge.c` — `JSBridge.eval` の C 実装 (12 行)
- `spike/host/adapter.js` — JS 側ホスト (handle table, js_eval, WASI shim, no-op stubs)
- `spike/host/index.html` — ブラウザエントリ
- `spike/stubs/` — POSIX ヘッダの最小スタブ群
- `docs/mruby-bridge.md` — 設計メモ。Phase 0 調査結果と Phase 2 以降の方針を含む

## 8. 評価

「**自分で C を書いて mruby + WASI で kotoyomi の Ruby が動く JS bridge を作る**」というアプローチは、開発工数 1 日で feasibility が立証された。`js` gem や `mruby-js` を使わずに完結している。

ただし「Phase 2 で kotoyomi 本体に統合する」ところからが本番の規模感で、handle 管理・callback marshalling・Promise 代替など、思考の伴うタスクが残る。Spike が成功したことで、これらの設計判断を実装ベースで詰められる足場ができた。
