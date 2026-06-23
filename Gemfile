# frozen_string_literal: true

source "https://rubygems.org"

# ローカル動作確認用の静的ファイルサーバ。`bundle exec wsv` で起動。
gem "wsv"
gem "rubocop"

# ビルド時 CLI(Kotoyomi::CLI = cli/)が Markdown を解析するのに使う。
# red_quilt は隣のチェックアウトを参照(sibling 規約)。
gem "red_quilt", path: "../red_quilt"

# テスト: ビルド CLI は rspec(spec/)、slides.json 取り込みは minitest(test/)。
gem "rspec"
gem "rake"
