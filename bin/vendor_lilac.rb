# frozen_string_literal: true

# vendor/lilac/ に Lilac の :full ランタイム(release wasm + mruby-wasm-js
# ブリッジ)を取り込む。`make vendor-lilac` から呼ばれる。
#
# 取得元は lilac-wasm-bin gem の `Lilac::Wasm::Bin` パス解決。Makefile が
# `-I <lilac>/wasm-bin/lib` を渡すので gem を bundle にインストールせずに
# require できる(gem の wasmtime 依存は「.rb→.mrb コンパイル」用で、ここの
# ファイルコピーには不要なため、kotoyomi の Gemfile には載せない)。
#
# 解決順は `data/`(リリース gem 同梱) → monorepo の `*.release.wasm` →
# dev wasm。隣チェックアウト利用時も release(約 0.8MB)を取り込む。
# 公開された gem に切り替える場合は Makefile の -I を外し Gemfile に
# `gem "lilac-wasm-bin"` を足すだけで、このスクリプトはそのまま使える。

require "lilac/wasm/bin"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
DEST = File.join(ROOT, "vendor", "lilac")
BRIDGE_DEST = File.join(DEST, "mruby-wasm-js")

wasm = Lilac::Wasm::Bin.lilac_full_wasm
abort "lilac-full.wasm not found — run `make -C ../lilac lilac-full-release` first" unless wasm
bridge = Lilac::Wasm::Bin.mruby_wasm_js_dir
abort "mruby-wasm-js bridge not found" unless bridge

FileUtils.rm_rf(DEST)
FileUtils.mkdir_p(BRIDGE_DEST)

# wasm の vendored 名は lilac.wasm 据え置き(ruby_runtime.js の WASM_URL と一致)。
FileUtils.cp(wasm, File.join(DEST, "lilac.wasm"))

# ブリッジはトップ階層の通常ファイルのみ(サブディレクトリはビルド成果物で
# ランタイムは読まない。lilac-cli の VendorWriter と同じ flat-copy 規約)。
Dir.glob(File.join(bridge, "*")).each do |entry|
  next if File.directory?(entry)
  FileUtils.cp(entry, File.join(BRIDGE_DEST, File.basename(entry)))
end

kb = File.size(File.join(DEST, "lilac.wasm")) / 1024
puts "vendored lilac-full (release, #{kb}KB) + mruby-wasm-js bridge → vendor/lilac/"
