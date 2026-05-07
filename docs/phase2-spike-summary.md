# Phase 2a–2d Spike サマリ — JS bridge と kotoyomi 本体の mruby 移植

**期間**: 2026-05-07 〜 2026-05-08 (Phase 1 完了直後から連続で実施)
**ブランチ**: `spike/mruby-bridge`
**結果**: ✅ 成功 (kotoyomi sample がブラウザで mruby 経由で動作)

## 1. 目的と成功条件

Phase 1 で「自前 mrbgem で `Kotoyomi::JS.eval` が動く」ところまでは行ったが、kotoyomi 本体を載せ替えるには get/set/call/callback/Float/object literal/null 判定など多数の primitive が必要。

このフェーズでは、`docs/mruby-bridge.md` で「Phase 2 で必要」とした API を一式実装し、ruby.wasm の `js` gem に書かれているのと同等の Ruby らしい使用感 (`obj.method(arg)`, `obj[:key] = v`, `obj.then { ... }`) を mruby + 自前ブリッジで成立させる。

成功条件:

1. `Kotoyomi::JS::Value` が C-backed (MRB_TT_DATA) で、Ruby GC で JS handle が自動 release される
2. ruby.wasm 互換の API (`global`, `[]/[]=`, `.call`, `to_s/to_i/to_f`, `nil?`, `on`) が動く
3. ruby.wasm 同様 `BasicObject` サブクラスにして、Object 由来メソッド (`then`, `tap`, `==`) との衝突なく `method_missing` で JS にディスパッチできる
4. block-as-callback (`elem.on(:click) { ... }`, `promise.then { |v| ... }`) が双方向で動く
5. Promise#await を使わずに「track の load を待つ」パターン (event-once + callback) が書ける

5 つすべて達成。

## 2. 達成した最終構成

### Ruby 側 API (`mrblib/kotoyomi_js.rb`, 143 行)

| API | 役割 |
|---|---|
| `JS.global` | `globalThis` の Value |
| `JS.eval(src)` | 任意 JS を評価して結果を Value で受ける |
| `JS.callback(&block)` | Ruby block を JS コールバック関数に marshal |
| `JS.wrap(v)` | Ruby 値 → Value (Integer/Float/String/nil/true/false/Value 対応) |
| `JS.object(hash)` | Ruby Hash → JS object literal (`{ once: true }` 等) |
| `Value#[]` `#[]=` | プロパティ get/set |
| `Value#call(method, *args, &block)` | JS メソッド呼び出し。block は最後の引数として callback 化 |
| `Value#to_s` `#to_i` `#to_f` | プリミティブ取り出し |
| `Value#nil?` | JS の `null`/`undefined` 判定 |
| `Value#on(event, options=nil, &block)` | `addEventListener` のエルゴノミック alias |
| `Value#method_missing` | `obj.method(args)` / `obj.attr = v` / `obj.predicate?` を JS にフォワード |

### C 側 primitive (`mrbgem/kotoyomi-js/src/kotoyomi_js.c`, 335 行)

15 個の WASM imports と Ruby から呼ぶ C 関数:

- 値変換: `_eval`, `_global`, `_release`, `_get`, `_set`, `_call`
- スカラ往復: `_to_string`, `_from_string`, `_to_int`, `_from_int`, `_to_float`, `_from_float`, `_is_null`
- callback: `_make_callback`, `kotoyomi_invoke_proc` (export)

### JS 側 adapter (`host/adapter.js`, 296 行)

- ハンドルテーブル (`alloc/get/release`、index 0 は null sentinel、free list 再利用)
- 上記 imports の実装
- WASI shim (puts → console.log のための fd_write など 12 個)
- mruby-io HAL の no-op stub 26 個

### 最終バイナリサイズ

`mruby.wasm`: **約 4.2MB** (Phase 1 の 4.1MB から +約 70KB、`mruby-method` gem 追加分)

## 3. 段階別の達成内容

### Phase 2a — primitive の API 化

最初は整数 handle を直接 Ruby から触る薄い実装。`_eval`/`_global`/`_get`/`_set`/`_call`/`_to_string`/`_from_string` を C で実装、Ruby 側に `Kotoyomi::JS::Value` を **mrblib の純 Ruby** で定義 (`@handle` を ivar 保持)。これだけで `JS.global[:document][:title] = "..."` が書けるようになった。

### Phase 2b — Value を C-backed (MRB_TT_DATA) 化 + 自動 release

純 Ruby 実装だと「Value が GC されたあとも JS handle は alloc しっぱなし」になる。`MRB_TT_DATA` で Value を再定義し、`mrb_data_type` の free callback (`js_value_free`) から `js_release` を呼ぶように変更。これで連続再生のメモリリーク懸念が解消。

注意点: `wrap` で作る一時 Value を `Value#call` 中に local 変数で保持しないと、`.handle` 抽出と `js_call` の間に GC が走って handle が release されてしまう (実際に踏んだ)。`wrapped = args.map { |a| JS.wrap(a) }` をローカルに残すパターンで防ぐ。

### Phase 2c — block-as-callback (双方向 marshalling)

`JS.callback(&block)` が Ruby Proc を C 側のコールバックテーブル (Hash、`mrb_gc_register` で pin) に登録し、JS 側に integer id を渡して `js_make_callback(id)` で wrapper function を生成。wrapper が呼ばれると `instance.exports.kotoyomi_invoke_proc(id, args_handle)` で mruby に戻り、登録済み Proc を `mrb_yield_argv` で呼び出す。

これにより `elem.addEventListener("click") { |ev| ... }` や `promise.then { |v| ... }` が成立。

#### 副題: BasicObject 化

ruby.wasm の `JS::Object` と同じく、`Kotoyomi::JS::Value < BasicObject` に変更。理由:

- `Object#then` は `yield_self` の alias で、引数の block を yield して返す。これがあると `promise.then { ... }` が JS にディスパッチされず、mruby 側で同期 yield されてしまう
- `Object#tap`/`itself`/`==`/`inspect` も同様の衝突を起こす
- 1 個ずつ override する手もあるが、将来 Ruby に追加されたメソッドが衝突したときに気づきにくい

BasicObject 化に伴う制約:

- `Integer`/`String`/`ArgumentError` などの top-level 定数が ancestor 経由で見えない → `wrap` を `JS` モジュール関数として外出し
- `Kernel#raise`/`#nil?` が無い → `nil?` を Value の instance method として実装、`raise` は module 関数側のみで使用

### 「await の代替」パターン

mruby は標準で fiber/Asyncify を持たないため、ruby.wasm の `JS.eval(...).await` 相当はそのままでは作れない。代わりに 2 系統のパターンで吸収:

- **値が来るパターン**: `promise.then { |v| ... }` (Phase 2c で動作確認)
- **イベントが来るパターン**: `target.on(event, JS.object(once: true)) { |ev| ... }` (Phase 2c で動作確認)

`wait_for_track_load` は後者で書き換える方針。

### Phase 2d — kotoyomi 本体の mruby 移植

`spike/app/{dom,renderer,player,kotoyomi}.rb` として `lib/*.rb` を移植。`spike/host/sample/` に既存 `works/sample/` と同等の HTML/audio/track を用意して、ブラウザで sample.mp3 + sample.vtt の再生・ハイライト遷移・「最初に戻る」が ruby.wasm 版と同じ挙動で動くことを確認。

#### 主な変更点

1. **JS 駆動のロード機構** — main.c から SCRIPT 埋込みを撤去、`mrb_open()` だけ呼んで生かしておき、JS 側が `kotoyomi_eval_handle(handle)` export 経由で `.rb` を 1 ファイルずつ送り込む。`evalRuby(source)` ヘルパを adapter.js に追加
2. **callback 内例外の捕捉** — `kotoyomi_invoke_proc` で `MRB_TRY/CATCH` を仕掛けて、Ruby 例外が SJLJ longjmp で wasm boundary を越えて host を `unreachable` でクラッシュさせないようにした
3. **`wait_for_track_load` の書き換え** — `JS.eval(...).await` をやめて、`@track_el.on(:load, JS.object(once: true)) { proceed.call }` の callback パターンに。`App#start` は同期セットアップ + listener 登録だけ行い、本体処理は `on_track_loaded` に分離
4. **listener wrapper の rooting** — `Kotoyomi::JS::Value#on` が返す callback Value は呼び出し側で保持しないと GC される。`DOM::Element` と `Player` で `@callbacks << @node.on(...)` パターンで生存期間中 pin
5. **`mruby-regexp` の除外** — stdlib gembox に含まれる `mruby-regexp` の mrblib が `String#split` を再定義し、plain string 引数で `super` に落とす作りだが、同クラス上の override は super で C 実装に届かず "no superclass method 'split' for String" になる。kotoyomi では regexp 不要なので `conf.gems.instance_variable_get(:@ary).reject!` で削除

#### sample 用ホスティング

ブラウザでの動作確認のため `spike/host/sample/index.html` を追加。docroot を `spike/` に上げ、

- `/host/sample/index.html` — kotoyomi player UI
- `/host/boot-kotoyomi.js` — adapter import + `.rb` ファイル fetch + `Kotoyomi.start`
- `/host/mruby.wasm` — ビルドされた wasm
- `/app/{dom,renderer,player,kotoyomi}.rb` — Ruby ソース

の構成で動作。Makefile の `serve` ターゲットも対応。

#### Node smoke runner

`host/run-kotoyomi-node.mjs` を追加。最小 DOM/EventTarget/Audio shim と fake cue を仕込み、`Kotoyomi.start` → simulate track load → `poem.children.length == 2` まで Node 上で確認できる。CI/回帰テストに使える形。

## 4. 解決した技術課題

### (1) Promise から渡された値が常に 0 になる

**症状**: `Promise.resolve(42).then { |v| puts v.to_i }` が `0` を出力

**経緯**: 最初は GC 起因 (一時 Value が `.handle` 取り出しと `_call` の間に GC されて release) を疑い `wrapped` を local に残す変更で対処。が、症状は残る

**根本原因**: mruby に `mruby-object-ext` が default で入っており、`Object#then` (= `yield_self`) が定義されていた。`Value < Object` のため `then` が method_missing より先にマッチし、JS の `Promise#then` ではなく **同期 yield** が走っていた。block には Promise (の Value) が渡されていたので `to_i` で `0`

**解決**: `Value < BasicObject` に変更。これで `Object#*` が一切継承されなくなり、`method_missing` が常に発火するようになった

### (2) `cb = JS.callback(&block)` した後の handle が即 release される

**症状**: `[trace] js_release h=N (was function)` が `addEventListener` のあと立て続けに出て、コールバックが発火しない

**原因**: `Value#on(event, &block)` の中で `cb = JS.callback(&block); call(:addEventListener, event, cb)` と書いていたが、`call` から戻った直後に `cb` がスコープから消えて GC 対象になり、ラッパー関数の handle が release されてしまう。一方 JS 側の `addEventListener` はそのラッパー関数を internal listener list で握っているが、handle 経由の参照は切れたので mruby から見ると死んだ参照

**解決**: `on` で `return cb` するように変更。呼び出し側 (`@track_el.on(:load) { ... }`) で受け取った Value を保持しておけば release されない。callback 自体は C 側のコールバックテーブルに pin されているのでこれで十分

### (3) BasicObject 配下で定数が見えない

**症状**: `case v when Integer then ...` が `NameError: uninitialized constant Kotoyomi::JS::Value::Integer`

**原因**: lexical nesting は `[Value, JS, Kotoyomi]` だが、constant lookup が cref ancestor を辿ったとき Value の親が BasicObject なので Object に届かない

**解決**: `wrap` を `JS` モジュール関数 (`def self.wrap(v)`) として移動。モジュール本体内では `self == Kotoyomi::JS` で nesting にも cref にも Object が入っているため top-level 定数が見える

### (4) `puts value.to_s` で内部 `to_s` が呼ばれない

最初 `Value#to_s` を `JS._to_string(handle)` で実装したが、`puts` は内部で `mrb_funcall(mrb, v, "to_s", 0)` を呼ぶ実装。BasicObject では `to_s` も継承されないので、自前で定義しておく必要がある (これは元々定義済みだったが、BasicObject 化の文脈で意識した)

### (5) `method_missing` の発火に `mruby-method` gem が必要

**症状**: `doc.title = "x"` が `NoMethodError: undefined method 'title=' for ...`

**原因**: mruby は default で method_missing をサポートしていない。`mruby-method` gem を入れると `Kernel#method_missing` の hook が有効になる

**解決**: `build_config/wasi.rb` に `conf.gem core: "mruby-method"` を追加

### (6) callback 内 Ruby 例外で wasm が `unreachable` クラッシュ

**症状**: `kotoyomi_invoke_proc` 経由で発火した callback の中で例外が起きると、Node が `RuntimeError: unreachable at __wasm_setjmp_test` で落ちる

**原因**: mruby の例外は SJLJ で実装されており、`mrb_yield_argv` 内で raise されると `mrb->jmp` の jmpbuf へ longjmp する。`mrb_load_string` 経由で呼ばれた場合は parser 側が jmpbuf を仕込むが、wasm export 直下から呼ぶ場合は jmpbuf がなく longjmp が host boundary を escape して `__wasm_setjmp_test` の `unreachable` に到達

**解決**: `kotoyomi_invoke_proc` で自前の `struct mrb_jmpbuf` を立て、`MRB_TRY/CATCH/MRB_END_EXC` で囲う。catch 側で `mrb_print_error` + `mrb->exc = NULL` してから抜ける

### (7) `mruby-regexp` の `String#split` が `super` で C 実装を見失う (upstream バグ)

**症状**: `"a\nb".split("\n")` が `NoMethodError: no superclass method 'split' for String`

**原因 (mruby-regexp 側のバグ)**:

1. core `mruby/src/string.c` が `mrb_define_method(String, "split", mrb_str_split_m)` で C 実装を登録
2. `mrbgems/mruby-regexp/mrblib/string_regexp.rb` が `class String; def split(pattern = nil, limit = -1); ... end` で同じ String クラス上に Ruby 版 split を定義
3. mruby の method table (`class.c:mt_put`) はキー重複時に **既存エントリを上書き** する。チェーン保持はしない (`entries[i].val = ptrval; return`)。よって C 実装の登録は消える
4. mrblib の split は plain-string pattern の場合 `return super if pattern.length == 1 || !pattern.include?('\\')` で C 実装に落とそうとする
5. mruby の `OP_SUPER` (`vm.c`) は **呼び出し元メソッドの定義クラスの親クラス** から探索を開始する: `ci->u.target_class = ... CI_TARGET_CLASS(ci - 1)->super`
6. 呼び出し元の定義クラスは String なので、`String.super == Object` から探索 → Object に split 無し → エラー

mruby-regexp の test (`mrbgems/mruby-regexp/test/regexp.rb`) は Regexp pattern (`/,\s*/`) しか試しておらず、super フォールバック経路は **テストで踏まれていない** ので、この破壊が gem 配布まで残っている。

**解決**: 我々の用途では regexp 不要なので、`build_config/wasi.rb` で gembox 注入後に gem 一覧から除外:

```ruby
conf.gembox "default-no-stdio"
conf.gems.instance_variable_get(:@ary).reject! { |g| g.name == "mruby-regexp" }
```

stdlib gembox から個別 gem を抜く公式 API が `MRuby::Build` に無いので、`Gem::List` の `@ary` ivar を直接いじる必要あり。

**上流に出すなら**:

```ruby
class String
  alias __core_split split   # 再定義前に C 実装を別名で保存
  def split(pattern = nil, limit = -1)
    return __core_split(pattern, limit) if pattern.nil? || ...
    ...
  end
end
```

のような `alias` パターンが正しい。super は使えない (mruby の method 上書きセマンティクス上)。

## 5. ハマらなかった/楽だった点

- **MRB_TT_DATA + free callback** は素直 (struct + `mrb_data_type` 定義 + `mrb_data_init` だけ)。GC のタイミングは保証されないが kotoyomi 用途では問題なし
- **コールバックテーブル** は Ruby Hash でそのまま実現できた。`mrb_gc_register` で pin するだけで十分 (個別の WeakRef 等は不要)
- **`mrb_yield_argv`** で Proc に引数配列を渡せるので、可変長 callback の取り回しは楽

## 6. 残課題 (Phase 2e 以降)

### 機能面

- **エラー伝搬** — JS 例外が `js_call` 経由で投げられたとき、現状は `console.error` してから handle 0 を返すだけ。`Kotoyomi::JS::Error < StandardError` を立てて Ruby 側に伝搬させたい (`wait_for_track_load` の `rescue JS::Error` は今は到達不可)
- **`Value#==`** — 現状は method_missing 経由で JS の `==` にフォワードされる。Ruby らしくは `Value#==` を「同じ JS 値を指すか」で実装するのが妥当
- **`inspect`** — BasicObject なので `p value` が動かない。デバッグ用に最小実装が欲しい

### 性能・配布

- **mrbc 化** — `.rb` を bytecode に precompile して `.mrb` 配信したい (起動時のパース時間 + sourceサイズの両面)
- **bundle** — 現状 4 ファイル fetch + evalRuby を 4 回呼んでいる。1 つに concat した方が往復が減る

### kotoyomi 本体への置き換え (Phase 2e)

spike 上で動くことは確認済み。次は top-level 側を mruby に切り替える:

- `lib/*.rb` を `spike/app/*.rb` の内容で上書き (`require "js"` 行を削るだけで両立可)
- `src/ruby_runtime.js` を `spike/host/boot-kotoyomi.js` ベースで書き直し (`DefaultRubyVM` ではなく自前 `boot()`)
- `src/main.js` のエラーハンドリングを継承 (start 失敗時のフォールバック)
- `mruby.wasm` の配布方法決定 (vendor 同梱 vs ビルド時生成)

### Phase 6 (将来): picoruby

picoruby は mruby/c ベースで Class 定義に制約があるため、`Kotoyomi::JS::Value < BasicObject` がそのまま通るかは要確認。Phase 2 の mruby ブリッジが安定してから別タスクで検討

## 7. 再現手順

```bash
git switch spike/mruby-bridge
cd spike
make all                  # Phase 1 から変更なし
make serve                # docroot は spike/、http://localhost:8001/host/sample/ で kotoyomi sample
```

ブラウザで http://localhost:8001/host/sample/ を開くと既存 `works/sample/` と同じ poem player UI が表示され、再生でハイライトが連ごとに移り、「最初に戻る」ボタンで先頭に戻る。

Node 上での smoke 実行も可能:

```bash
node host/run-node.mjs           # Phase 2c 機能 (BasicObject + await 代替)
node host/run-kotoyomi-node.mjs  # kotoyomi 起動シナリオ (poem.children: 2 を確認)
```

期待する出力 (`run-node.mjs` — Phase 2c 機能を JS-driven evalRuby で再演):

```
[mruby] BasicObject + await-replacement test
[doc] title = BasicObject OK
[mruby] 1. title = BasicObject OK
[mruby] 2. float = 3.75
[mruby] 3. opts.once = true
[mruby] 4. nil? = true
[mruby] 6. ready event fired
[mruby] sync part done
[mruby] 5. promise resolved: 7
```

(`debug.trace = true` を設定すると adapter.js の `[trace]` 系も出る。既定では off)

## 8. 関連ファイル

| ファイル | 役割 |
|---|---|
| `spike/mrbgem/kotoyomi-js/src/kotoyomi_js.c` | C primitive + `kotoyomi_eval_handle` export (約 350 行) |
| `spike/mrbgem/kotoyomi-js/mrblib/kotoyomi_js.rb` | Ruby ラッパー、BasicObject ベース (143 行) |
| `spike/main/main.c` | `mrb_open()` だけ (SCRIPT 埋込みは廃止、Phase 2d) |
| `spike/host/adapter.js` | JS host adapter、handle table、imports、`evalRuby`、`debug.trace` (約 305 行) |
| `spike/host/boot-kotoyomi.js` | kotoyomi sample 用の boot エントリ (`.rb` fetch + evalRuby) |
| `spike/host/sample/index.html` | kotoyomi player の HTML (`works/sample/index.html` と同等) |
| `spike/host/run-node.mjs` | Phase 2c 機能の Node smoke |
| `spike/host/run-kotoyomi-node.mjs` | kotoyomi 起動シナリオの Node smoke |
| `spike/app/{dom,renderer,player,kotoyomi}.rb` | `lib/*.rb` の mruby ポート版 (Phase 2d) |
| `spike/host/run-node.mjs` | Node smoke runner |
| `spike/main/main.c` | テストスクリプト埋込 main (59 行) |
| `spike/build_config/wasi.rb` | mruby を wasi-sdk + clang でビルドする設定 (`mruby-method` 追加、`mruby-regexp` 除外) |
| `docs/phase1-spike-summary.md` | Phase 1 (eval だけ) のサマリ |
| `docs/mruby-bridge.md` | Phase 0 設計 + 全 Phase ロードマップ |

## 9. 評価

Phase 1 は「絵に描いた eval が一回動く」段階だったが、Phase 2a–2c で **kotoyomi の lib コードがほぼそのまま載る形** までブリッジが育ち、Phase 2d で **実際にそのまま載った**。`BasicObject` 化と `method_missing` 委譲で `obj.method(arg)`/`obj.attr = v` の Ruby らしい記述が保て、ruby.wasm からの移植は `require "js"` の削除と `wait_for_track_load` の callback 化だけで済んだ。

`await` を持たない制約は当初の懸念だったが、kotoyomi では「Promise を then で繋ぐ」「load イベントを once で待つ」の 2 種類しか使っていないので、書き換えコストは限定的だった。

`mruby-regexp` の `String#split` バグ (super で C 実装に届かない) と、wasm export 直下から `mrb_yield_argv` を呼んで例外で `unreachable` クラッシュする問題は、想定外の伏兵だったが両方原因特定+回避済み。

次フェーズ (Phase 2e) は本体 lib の書き換えと `src/ruby_runtime.js` の差し替え。エラー伝搬 (`JS::Error`) は本体移植前にもう少し詰めておく価値がある (現状は handle 0 を返すだけで Ruby 側に raise されない)。
