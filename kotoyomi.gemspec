# frozen_string_literal: true

require_relative "cli/lib/kotoyomi/cli/version"

Gem::Specification.new do |spec|
  spec.name = "kotoyomi"
  spec.version = Kotoyomi::CLI::VERSION
  spec.authors = ["TAKAHASHI Masayoshi"]
  spec.email = ["maki@rubycolor.org"]

  spec.summary = "音声同期プレイヤーを載せられる Web スライドビューア + 雛形 CLI"
  spec.description = "Markdown からスライドを生成・配信する kotoyomi の CLI。" \
                     "`kotoyomi new` で Lilac ランタイム同梱の作業ディレクトリを作り、" \
                     "`kotoyomi build` / `kotoyomi serve` で書いて見られる。"
  spec.homepage = "https://github.com/takahashim/kotoyomi"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  # CLI 本体(cli/lib)+ 実行ファイル + `kotoyomi new` が配る雛形(ランタイム一式)。
  spec.files = Dir[
    "exe/kotoyomi",
    "cli/lib/**/*",
    "index.html",
    "app.css",
    "src/**/*",
    "lib/**/*",
    "vendor/lilac/**/*",
    "viewer/index.html",
    "viewer/presenter.html",
    "viewer/print.html",
    "README.md"
  ]
  spec.bindir = "exe"
  spec.executables = ["kotoyomi"]
  spec.require_paths = ["cli/lib"]

  # ビルド(Markdown 解析)と serve(静的サーバ)に使う。
  spec.add_dependency "red_quilt", ">= 0.7.2"
  spec.add_dependency "wsv"
end
