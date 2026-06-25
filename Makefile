# ことよみ スライドビューア — ビルド/検証タスク。
#
# build        : examples を kotoyomi build(src/deck.md → public/viewer/slides.json)
# serve        : examples を kotoyomi serve(public/ 配信 + 監視 + 自動リロード)
# pdf          : 全スライドを 1 ページずつ並べた PDF を書き出す (要 Google Chrome)
# smoke        : ホストスモーク (wasmtime-rb + Dommy/QuickJS でデッキ/プレイヤーを検証)
# test         : Ruby テスト(rspec = ビルド CLI、minitest = slides.json 取り込み)
# vendor-lilac : 隣の lilac チェックアウトをビルドして vendor/lilac/ を更新
#
# ビルド CLI(Kotoyomi::CLI, MRI)は `cli/` に同梱。Markdown 解析に red_quilt を
# 使うため `../red_quilt`(sibling)が必要。
#
# ライブリロード: `make serve` 一つで配信 + src/deck.md 監視 + 自動リロードまで
# 担う(http://127.0.0.1:8000/viewer/)。deck.md を保存すると slides.json を再生成し、
# ビューアがその場で再描画する。
#
# examples/ は kotoyomi の実サンプルプロジェクト(src/deck.md + 生成物 public/)。
# make build / serve は kotoyomi build / serve に委譲する。public/ は生成物(gitignore)
# なので、初回や clone 直後は make build / serve が雛形から自動展開する(runtime ターゲット)。

# 操作対象の kotoyomi プロジェクト(src/deck.md + public/)。
PROJECT ?= examples

# vendor/lilac/ は Lilac の :full ランタイム(release wasm + mruby-wasm-js
# ブリッジ)。lilac-wasm-bin gem の `Lilac::Wasm::Bin` パス解決経由で取り込む
# (bin/vendor_lilac.rb)。隣チェックアウト利用時も release(約 0.8MB)を取得。
# 未リリースの lilac を手元で試すとき = lilac 側を編集 → `make vendor-lilac`。
#
# 注意: lilac の Make ルールは mrblib (*.rb) の変更を依存に持たないため、
# lilac の Ruby を編集しただけでは wasm が再ビルドされない (既存 .wasm を
# 最新とみなす)。Ruby を変えたら lilac 側で古い成果物を消してから:
#   rm -f ../lilac/build/lilac-full.release.wasm
#   rm -rf ../mruby-wasm-runtime/mruby/build/lilac-full-release
# その後 `make vendor-lilac` で確実に取り込まれる。
LILAC ?= ../lilac

# PDF 出力先。`make pdf PDF=foo.pdf` で変更可。Chrome のパスは CHROME=... で上書き。
PDF ?= kotoyomi.pdf

.PHONY: build serve runtime pdf smoke test spec vendor-lilac

build: runtime
	bundle exec exe/kotoyomi build "$(PROJECT)"

serve: runtime
	bundle exec exe/kotoyomi serve "$(PROJECT)"

# examples/public/ のランタイム(index.html / app.css / src / lib / vendor/lilac /
# viewer/*.html)を雛形から展開する。public/ は生成物(gitignore)なので、初回や
# clone 直後はこれで用意する。既にあれば何もしない。
runtime:
	@if [ ! -f "$(PROJECT)/public/index.html" ]; then \
		mkdir -p "$(PROJECT)/public" && bundle exec exe/kotoyomi upgrade "$(PROJECT)"; \
	fi

pdf: build
	PDF="$(PDF)" PDF_ROOT="$(PROJECT)/public" bash bin/pdf.sh

smoke:
	bundle exec ruby test/smoke/run_node.rb
	bundle exec ruby test/smoke/run_presenter.rb

spec:
	bundle exec rspec

test: spec
	ruby test/slides_test.rb

vendor-lilac:
	$(MAKE) -C $(LILAC) lilac-full-release
	ruby -I"$(LILAC)/wasm-bin/lib" bin/vendor_lilac.rb
	@echo "run 'make smoke' to verify"
