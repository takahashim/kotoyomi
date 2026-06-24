# frozen_string_literal: true

require_relative "cli/lib/kotoyomi/cli/version"

Gem::Specification.new do |spec|
  spec.name = "kotoyomi"
  spec.version = Kotoyomi::CLI::VERSION
  spec.authors = ["TAKAHASHI Masayoshi"]
  spec.email = ["maki@rubycolor.org"]

  spec.summary = "Web slide generator/viewer system with Ruby"
  spec.description = "Markdown からスライドを生成・配信する kotoyomi の CLI。" \
                     "`kotoyomi new` で Lilac ランタイム同梱の作業ディレクトリを作り、" \
                     "`kotoyomi build` / `kotoyomi serve` で書いて見られる。"
  spec.homepage = "https://github.com/takahashim/kotoyomi"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

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

  spec.add_dependency "red_quilt", ">= 0.8.0"
  spec.add_dependency "wsv"
end
