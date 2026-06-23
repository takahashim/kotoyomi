# frozen_string_literal: true

source "https://rubygems.org"

# kotoyomi gem 本体(kotoyomi.gemspec)。`kotoyomi` 実行ファイルと依存(red_quilt /
# wsv)はここから来る。`bundle exec kotoyomi …` が使えるのもこのため。
gemspec

# red_quilt は開発中は隣のチェックアウトを使う(gemspec の依存を path で上書き)。
gem "red_quilt", path: "../red_quilt"

# 開発用。
gem "rubocop"
gem "rspec"
gem "rake"
