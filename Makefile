# ことよみ スライドビューア — ビルド/検証タスク。
#
# build        : Markdown デッキ → viewer/slides.json (ビルド CLI = cli/)
# watch        : deck.md を監視して slides.json を再生成(ブラウザは自動で再描画)
# serve        : ローカル静的サーバ (wsv)。viewer/ をブラウザで開く
# pdf          : 全スライドを 1 ページずつ並べた PDF を書き出す (要 Google Chrome)
# smoke        : ホストスモーク (happy-dom 上でデッキ/プレイヤーを検証)
# test         : Ruby テスト(rspec = ビルド CLI、minitest = slides.json 取り込み)
# vendor-lilac : 隣の lilac チェックアウトをビルドして vendor/lilac/ を更新
#
# ビルド CLI(Kotoyomi::CLI, MRI)は `cli/` に同梱。Markdown 解析に red_quilt を
# 使うため `../red_quilt`(sibling)が必要。
#
# ライブリロード: 別ターミナルで `make serve` と `make watch` を起動し、
# http://127.0.0.1:8000/viewer/ を開く。deck.md を保存するとビルド CLI が
# slides.json を再生成し、ビューア(localhost のみ)が検知してその場で再描画する。
#
# CI にはビルド環境(red_quilt)が無い前提なので viewer/slides.json と
# viewer/media/ はコミットし、デッキを編集したら手元で `make build` して再生成する。

DECK      ?= examples/deck.md
TITLE     ?= ことよみ Slides
DECK_LANG ?= ja

# vendor/lilac/ は隣の lilac チェックアウトの `make pages-pack` 成果物
# (lilac.wasm + index.js + mruby-wasm-js ブリッジ一式) を丸ごと取り込んだもの。
# 未リリースの lilac を手元で試すとき = lilac 側を編集 → `make vendor-lilac`。
#
# 注意: lilac の Make ルールは mrblib (*.rb) の変更を依存に持たないため、
# lilac の Ruby を編集しただけでは wasm が再ビルドされない (既存 .wasm を
# 最新とみなす)。Ruby を変えたら lilac 側で古い成果物を消してから:
#   rm -f ../lilac/build/lilac-full.release.wasm
#   rm -rf ../mruby-wasm-runtime/mruby/build/lilac-full-release
# その後 `make vendor-lilac` で確実に取り込まれる。
LILAC         ?= ../lilac
LILAC_VERSION ?= vdev

# PDF 出力先。`make pdf PDF=foo.pdf` で変更可。Chrome のパスは CHROME=... で上書き。
PDF ?= kotoyomi.pdf

.PHONY: build watch serve pdf smoke test spec vendor-lilac

build:
	bundle exec exe/kotoyomi --format json \
		--title "$(TITLE)" --lang $(DECK_LANG) \
		-o viewer/slides.json "$(DECK)"
	@echo "wrote viewer/slides.json from $(DECK)"

watch:
	bundle exec exe/kotoyomi --format json --watch \
		--title "$(TITLE)" --lang $(DECK_LANG) \
		-o viewer/slides.json "$(DECK)"

serve:
	bundle exec wsv

pdf: build
	PDF="$(PDF)" bash bin/pdf.sh

smoke:
	npm run smoke

spec:
	bundle exec rspec

test: spec
	ruby test/slides_test.rb

vendor-lilac:
	$(MAKE) -C $(LILAC) pages-pack VERSION=$(LILAC_VERSION)
	rm -rf vendor/lilac
	mkdir -p vendor/lilac
	cp -R "$(LILAC)/dist-pages/$(LILAC_VERSION)/." vendor/lilac/
	@echo "vendored lilac ($(LILAC_VERSION)) into vendor/lilac/ — run 'make smoke' to verify"
