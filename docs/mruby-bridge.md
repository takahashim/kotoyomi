# mruby-bridge 設計メモ (Phase 0)

`js` gem / `mruby-js` に依存せず、kotoyomi 専用の自前 mrbgem として JS interop を C で実装するための **設計メモ**。実装着手前に「決まっていること」「調査が必要なこと」を整理しておくことで、後の spike (Phase 1) を漏れなく着手できるようにする。

このドキュメントは [`/Users/maki/.claude/plans/sped-md-kotoyomi-sorted-taco.md`](Phase 0-1 の plan) に対応する作業のためのもの。

## 1. 目的

- ruby.wasm の `js` gem を使わず、kotoyomi の lib コードがそのまま動くだけの **JS interop 層を C で自作する**
- 将来 mruby (より小さなランタイム) や picoruby (さらに小さなランタイム) に移植可能にする
- ハンドルテーブル、callback marshalling、Promise 連携などの技術要素を自分の手で扱う

## 2. ビルドターゲット候補

mruby の WASM ビルドには複数の選択肢がある。Phase 0 でどれを採るか確定する。

| 方式 | 概要 | 利点 | 不確実性 |
|---|---|---|---|
| Emscripten | mruby を Emscripten で WASM 化 | 多くの先行例あり、stdio 等もエミュレートされる | バイナリサイズが膨らむ、wasi 準拠ではない |
| wasi-sdk | clang + wasi-sysroot で WASM 化 | 軽量、ruby.wasm と同じ哲学 | mruby の build_config を WASI 用に手書き必要 |
| picoruby standalone | picoruby は最初から組み込み志向 | サイズ最小 | WASM 公式ビルドの成熟度が低い |

**初期推奨**: **wasi-sdk** で mruby を WASM 化。ruby.wasm が wasi で動いている前例があり、ブラウザ側でも WASI shim を使えば走る。サイズも小さい。

実際に試すまで不確実な要素が残る:
- mruby の `build_config.rb` で WASI ターゲットがどこまで通るか
- mrbc (bytecode コンパイラ) と mruby (interpreter) を一緒に WASM 化する必要があるか
- `wasi-libc` だけで mruby が要求する POSIX 関数を満たせるか

## 3. ハンドルテーブル設計

JS と mruby の間で参照を渡す基本構造。

### JS 側

```js
const handles = [null]; // index 0 は null sentinel
const free_list = [];

function handle_alloc(value) {
  if (free_list.length > 0) {
    const h = free_list.pop();
    handles[h] = value;
    return h;
  }
  handles.push(value);
  return handles.length - 1;
}

function handle_get(h) { return handles[h]; }
function handle_release(h) {
  handles[h] = null;
  free_list.push(h);
}
```

ハンドルは Int32 で表現 (WASM ABI で扱いやすい)。

### mruby 側

`mrb_data_object_init` で handle 値を保持する Ruby ラッパーを作る:

```c
typedef struct { int handle; } js_value_t;

static void js_value_free(mrb_state *mrb, void *ptr) {
  js_value_t *v = (js_value_t *)ptr;
  if (v) {
    js_release(v->handle); // WASM import
    mrb_free(mrb, v);
  }
}

static const mrb_data_type js_value_type = { "JSValue", js_value_free };
```

これで mruby GC が回収すると自動的に JS 側 `handle_release` が呼ばれる。

## 4. WASM imports / exports

JS から mruby へ提供する import 関数:

```text
// JS (Adapter)
js_eval(ptr_to_str, len) -> handle
js_get(handle, ptr_to_key, key_len) -> handle
js_set(handle, ptr_to_key, key_len, value_handle)
js_call(handle, ptr_to_method, method_len, argc, ptr_to_args) -> handle
js_release(handle)

// 値変換
js_to_int(handle) -> i32
js_to_float(handle) -> f64
js_to_string(handle, ptr_buf, buf_len) -> string_len
js_from_int(i) -> handle
js_from_float(f) -> handle
js_from_string(ptr, len) -> handle

// Callback
js_register_callback(callback_id) -> handle  // JS 側で wrapper 関数を作る
js_invoke_callback(callback_id, args_handle)  // mruby 側から呼ばれる (export)
```

mruby から JS へ export する関数:

```text
mruby_invoke_proc(proc_handle, args_handle) -> handle
mruby_release_proc(proc_handle)
```

## 5. Callback marshalling

Ruby block を JS callback として渡す流れ:

1. mruby 側で `Proc` に proc_handle (mruby の object table 上の番号) を割り振る
2. JS の `js_register_callback(proc_handle)` を呼ぶ
3. JS 側で wrapper 関数を作る:
   ```js
   const fn = (...args) => {
     const args_handle = handle_alloc(args);
     mruby_invoke_proc(proc_handle, args_handle);
   };
   ```
4. wrapper 関数のハンドルを返す
5. mruby はそれを `addEventListener` 等の引数として使う

問題: proc_handle の lifecycle 管理。Ruby Proc が GC されたら JS 側でも release する必要がある (Proc#free か mruby data type)。

## 6. Promise / await

mruby は標準で fiber を持たない。`mruby-fiber` gem を入れる選択肢はあるが、ruby.wasm の `Promise#await` のような透過的な実装は無い。

### 選択肢

| 選択 | 概要 | コスト |
|---|---|---|
| Fiber + scheduler 自作 | mruby-fiber を組み込み、`await` 相当の API を mrbgem で書く | 高 |
| Callback パスに書き換え | `JS.eval(...).await` を `JS.eval_async(...) { |result| ... }` に変更 | 中 (kotoyomi コード一部書き換え) |
| ハイブリッド | JS 側で `Promise.then` してから mruby callback を呼ぶ | 中 |

**初期推奨**: **callback パスに書き換え**。kotoyomi で `await` を使っているのは `wait_for_track_load` のみなので、ここを callback ベースに書き換えるコストは小さい:

```ruby
# 改修案
def wait_for_track_load(&block)
  ready = @track_el[:readyState].to_i
  return block.call if ready == 2
  raise TrackLoadError, "track load error" if ready == 3
  
  JS.eval_async(<<~JS) { block.call }
    return new Promise((resolve, reject) => { ... });
  JS
end
```

呼び出し側も `wait_for_track_load { do_rest }` のスタイルに変更。

## 7. ランタイムへの組み込み

```text
[Browser]
  index.html
    └─> src/main.js (ESM)
         └─> src/ruby_runtime.js (mruby version)
              ├─> fetch mruby.wasm  (自前ビルド)
              ├─> WASM instantiate (imports = bridge adapter)
              ├─> bridge adapter (handle table, callback marshalling)
              └─> mruby から Kotoyomi.start を eval
```

`src/ruby_runtime.js` を全面書き換えするか、`src/mruby_runtime.js` として並列に置いて切替可能にするかは別検討。最初は並列共存させて挙動比較できるようにすると安全。

## 8. mrbc vs runtime eval

| 方式 | 起動速度 | 配信サイズ | 開発中の利便性 |
|---|---|---|---|
| mrbc precompile | 速い | 小 (bytecode) | 編集ごとに再ビルド要 |
| runtime eval (`mrb_load_string`) | 遅い | やや大 (Ruby ソース) | 編集即反映 |

**初期推奨**: 開発中は **runtime eval** で生産性優先。本番リリース時に mrbc に切り替えるオプションを残す。

## 9. mrbgem の構成

```
mrbgems/mruby-js-bridge/
  mrbgem.rake             # gem 定義
  src/js_bridge.c       # C 実装 (handle bridge)
  mrblib/js_bridge.rb   # Ruby ラッパー (JSBridge module)
  test/                   # テスト (mruby test)
```

Phase 1 の spike では `src/js_bridge.c` で `js_eval` 1 つだけ実装、`mrblib/` で `JSBridge.eval(str)` を提供。

## 10. 想定 API (Phase 2 の確定前にスケッチ)

```ruby
module Kotoyomi
  module JS
    # 任意の JS ソース実行 (handle を返す)
    def self.eval(src) = ...

    # globalThis (固定 handle)
    def self.global = ...

    # JS 値ラッパークラス
    class Value
      def [](key)         = JS.get_property(self, key)
      def []=(key, val)   = JS.set_property(self, key, val)
      def call(method, *args) = JS.call_method(self, method, *args)
      def to_s            = JS.to_string(self)
      def to_i            = JS.to_int(self)
    end

    class Error < StandardError; end
  end
end
```

`Kotoyomi::DOM::Element` の内部実装を `JS::Value` に書き換えれば、上層 API (renderer/player/kotoyomi) は変えずに済む。

## 11. Phase 0 調査結果 (2026-05 時点)

Web リサーチで以下が判明:

### ビルドツールチェーン

- **wasi-sdk** + clang `--target=wasm32-wasip1` が現代的な WASM 用 C ツールチェーン
- ruby.wasm 自身が **Asyncify** を使って setjmp/longjmp / fiber / GC scan を疑似実装している。**mruby も同様に GC mark で setjmp 系を使うので、Asyncify が必要になる可能性が高い**
- WASI 0.3 (2026 リリース見込み) で native async が入ると Promise/await 連携が劇的に楽になる可能性
- **mruby.wasm ([elct9620/mruby.wasm](https://github.com/elct9620/mruby.wasm))** は Emscripten + WebIDL ベース。**更新が古く現代的な参考にはならない**。アプローチの比較程度

### 既存ソリューション: picoruby.wasm

**重要な発見**: 公式パッケージ [`@picoruby/wasm-wasi`](https://www.npmjs.com/package/@picoruby/wasm-wasi) (v3.4.5) が存在する。

- mruby VM をベースにした picoruby を WASI 向けにビルド済み、CDN 配布あり
- **`JS::Bridge` / `JS.global` / `JS.document` API を内蔵**しており、ruby.wasm の `js` gem に相当する機能を提供
- リポジトリ: <https://github.com/picoruby/picoruby/tree/master/mrbgems/picoruby-wasm>
- 作者は picoruby 創始者 (HASUMI Hitoshi)、RubyKaigi 2026 で Funicular フレームワークを発表
- mruby/c や mruby のコミッターでもあり、信頼性が高い

つまり「より小さなランタイム + JS bridge」の組み合わせは **既に存在する**。ただしユーザーの当初の意向は「**bridge も自前**」なので、picoruby.wasm を採用すると「bridge を作らない」ことになる。

### 進路選定

picoruby の方が小さい (mruby/c VM ベース) が、**Ruby 言語仕様の互換性に制約がある** (Class 構文の subset、metaclass の制限など)。kotoyomi のコードは `enum_for`、`each_with_index.map`、`attr_reader`、`alias`、`private` メソッド、独自 Error クラス階層などを使っており、picoruby だと個別に書き換え/検証が必要になる懸念が大きい。

→ **フル mruby を採用** することに決定。バイナリは picoruby より大きいが (それでも ruby.wasm より遥かに軽量見込み)、Ruby 互換性の保険として手堅い。picoruby.wasm は参考実装として存在を認識しておく程度。

### 採用方針 (確定)

- **ランタイム**: mruby (full、not mruby/c)
- **ビルド**: wasi-sdk + clang `--target=wasm32-wasip1`、必要なら Asyncify
- **JS bridge**: 自前で mrbgem を C 実装。`mruby-js` も使わない
- **アプリコード**: 既存 `lib/*.rb` の API を維持しつつ、`JSBridge` の内部実装を ruby.wasm `js` gem 経由から自前 bridge 経由に切り替え

参考実装として参照するもの:

- **ruby.wasm** の Asyncify 適用方法、wasi-sdk ビルド設定 (CRuby だが WASM ビルドの実例として一級)
- **picoruby.wasm の `JS::Bridge` 実装** (mrbgem の構造、handle 管理の参考。**主要参考**)
- mruby.wasm (elct9620) は更新が古く現代的な参考にはならない。アプローチの違い (Emscripten + WebIDL) を知る程度

## 12. 旧 Open questions の更新

| Q | 状態 |
|---|---|
| Q1: wasi-sdk + mruby ビルド設定 | △ ruby.wasm が参考。mruby 用は要試行。**picoruby.wasm のビルドスクリプトが最も近い参照** |
| Q2: wasi-libc 不足 POSIX 関数 | ○ ruby.wasm 経験から setjmp/longjmp が要 Asyncify |
| Q3: mruby-fiber wasi compat | × 未確認。callback ベース書き換えが現実解 |
| Q4: mrb_gc_register | △ mruby C API にあり (`mrb_gc_arena_save` 系)。要 mruby ソース確認 |
| Q5: picoruby WASM ビルド実例 | ◎ **picoruby.wasm として既存** |
| Q6: mrb_load_string エラーフォーマット | × 未確認 |
| Q7: バイナリサイズ目標 | △ picoruby.wasm のサイズ実測すれば現実値が分かる |

## 13. Phase 1 spike の最小成功条件

別ブランチ (`spike/mruby-bridge`) で:

1. `mruby.wasm` がブラウザで instantiate できる **✅ 達成**
2. `mruby_load_string("puts 'hello'")` 相当が呼べる (`puts` は console.log にリダイレクト) **✅ 達成**
3. `js_eval` import を実装し、Ruby から `JS.eval("document.title = 'Hi'")` でタイトルが変わる **✅ 達成**

→ **Phase 1 spike 完遂**。Phase 2 へ進む実現性が確認できた。

### 達成時の構成 (再現用メモ)

- **wasi-sdk 33.0** (arm64-macos)、`--target=wasm32-wasip1`
- **mruby v3.4 系** (master HEAD、shallow clone)
- **gembox**: `default-no-stdio` + `mruby-compiler` + `mruby-io` の最小構成
- SJLJ: `-mllvm -wasm-enable-sjlj` + `-lsetjmp` (libsetjmp.a が runtime を提供)
- 整合のため `main.c` 側にも `MRB_NO_BOXING -DMRB_UTF8_STRING` を渡す (定義の不一致で `mrb_value` のレイアウトが食い違うため)
- POSIX 不足分は `spike/stubs/` の force-include で吸収:
  - `pwd.h` (file.c が include するだけで未使用) → 空スタブ
  - `sys/wait.h` → `WEXITSTATUS` 等のマクロ + `waitpid` 宣言
  - `wasi-shims.h` を `-include` で強制注入し `dup` `waitpid` を宣言
- `--allow-undefined` で残った 30 個ほどの POSIX/HAL 関数は wasm imports 化、JS 側で no-op stub
- mruby.wasm 最終サイズ: **約 4.1MB** (ruby.wasm 比で 1/4 程度)

### 達成時の imports 構成

合計 40 個。内訳:
- **環境固有 (env)**: `dup`, `waitpid`, `mrb_hal_io_*` (24 個) — JS で no-op stub
- **WASI**: `fd_write` 等 12 個 — fd_write/fd_close/fd_fdstat_get は実装、残りはエラー返し
- **kotoyomi**: `js_eval` 1 個 — 実装済み (Function コンストラクタで eval、handle 返却)

### Phase 2 着手前にやり残し

- ハンドルテーブル: alloc は実装、release はまだ — 連続実行でリーク
- `JSBridge.eval` の戻り値がただの整数 handle、Ruby らしいオブジェクトでない (Phase 2 で `JS::Value` ラップ)
- `js_get` `js_set` `js_call` 等の追加 API 未実装 (Phase 2)

## 14. 進め方 (Phase 1 spike の具体手順)

### 14.1 ブランチ分離

`spike/mruby-bridge` ブランチを切って `main` / `webvtt` に影響を出さない位置で作業する。

### 14.2 picoruby.wasm のソース読解

実装着手前に最低限読んでおくべき場所 (mrbgem の構造、handle 管理の規範):

- `github.com/picoruby/picoruby` の `mrbgems/picoruby-wasm/` ディレクトリ
- 同リポ内に `JS::Bridge` 等の C 実装があるはず。ファイル構成と handle テーブルのコード規模を把握
- 何を flatten 模倣し、何を独自設計にするかを判断

### 14.3 wasi-sdk セットアップ

```bash
# macOS の例
brew install wasi-sdk    # or 公式リリース https://github.com/WebAssembly/wasi-sdk/releases
```

`WASI_SDK_PATH` を環境変数に設定。`clang --target=wasm32-wasip1` が動くこと確認。

### 14.4 mruby を WASM ビルド

1. mruby ソース取得 (`git clone https://github.com/mruby/mruby`)
2. `build_config/wasi.rb` を新規作成 (wasi-sdk の clang を指す)
3. `rake MRUBY_CONFIG=wasi` でビルド
4. 生成された `bin/mruby.wasm` (or `lib/libmruby.a`) を確認
5. **GC の setjmp/longjmp 周りで Asyncify が必要かを実機ロードで判断**。必要なら `wasm-opt --asyncify` を後段に挟む

### 14.5 最小 mrbgem (mruby-js-bridge) 作成

```
mrbgems/mruby-js-bridge/
  mrbgem.rake             # gem 定義
  src/js_bridge.c       # js_eval 1 関数のみ
  mrblib/js_bridge.rb   # JSBridge.eval(src) ラッパー
```

`src/js_bridge.c` の最小実装:

```c
extern int js_eval(const char *ptr, int len);  // WASM import

static mrb_value
mrb_js_eval(mrb_state *mrb, mrb_value self) {
  const char *src;
  mrb_int len;
  mrb_get_args(mrb, "s", &src, &len);
  int handle = js_eval(src, (int)len);
  return mrb_fixnum_value(handle);
}

void mrb_mruby_js_bridge_gem_init(mrb_state *mrb) {
  struct RClass *js = mrb_define_module(mrb, "JSBridge");
  mrb_define_module_function(mrb, js, "eval", mrb_js_eval, MRB_ARGS_REQ(1));
}
```

build_config に `conf.gem 'mrbgems/mruby-js-bridge'` を追記。

### 14.6 JS 側アダプタ

`spike/adapter.js`:

```js
const handles = [null];
const free = [];

function alloc(value) {
  if (free.length) { const h = free.pop(); handles[h] = value; return h; }
  handles.push(value); return handles.length - 1;
}

const memory = /* WASM instance memory */;

function js_eval(ptr, len) {
  const bytes = new Uint8Array(memory.buffer, ptr, len);
  const src = new TextDecoder().decode(bytes);
  // 危険: eval。spike だけ
  const result = (new Function(src))();
  return alloc(result);
}

const imports = {
  env: { js_eval },  // wasi-sdk の linker 設定次第
};

const wasm = await WebAssembly.instantiateStreaming(fetch("mruby.wasm"), imports);
// ...
```

### 14.7 ブラウザでの動作確認

最小成功条件 (Section 13 と同じ):

1. `mruby.wasm` がブラウザで instantiate
2. `mrb_load_string("puts 'hello'")` が動く (puts は console.log にリダイレクト要)
3. mruby 内 `JSBridge.eval("document.title = 'spike'")` でブラウザタブ名が変わる

ここまで来たら **feasibility 確認完了**、Phase 2 へ。

### 14.8 メモの更新

Phase 1 完了時、このドキュメントを実装知見で書き換える:

- 各 Open question (12 章) の状態を「○ 解決」「× 不可」「△ 部分」で確定
- 想定 API (10 章) を実装に基づき修正
- ハマりどころ・反省点を新セクションとして追記

---

main / webvtt ブランチには影響しない位置で作業し、Phase 1 が動かなかった場合は plan の戦略 B/C への退避を検討する。
