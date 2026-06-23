# frozen_string_literal: true

require "fileutils"

class Kotoyomi::CLI
  # `kotoyomi new DIR` の雛形生成。プロジェクトは2つのディレクトリに分かれる:
  #
  #   DIR/src/       … 作者が書くもの(deck.md と素材 assets/)
  #   DIR/public/    … 配信する静的サイト(ランタイム一式 + build 生成物)
  #
  # public/ はランタイム(index.html / app.css / src / lib / vendor/lilac /
  # viewer/*.html)を雛形からコピーしたもの + build が作る viewer/slides.json と
  # viewer/assets/。そのまま GitHub Pages 等へ置けば公開できる(Ruby 不要)。
  class Generator
    # public/ 直下にコピーするランタイムファイル(テンプレートルートからの相対)。
    RUNTIME_FILES = %w[
      index.html
      app.css
      src/main.js
      src/ruby_runtime.js
      src/hotreload.js
      src/fit-title.js
      lib/bus.rb
      lib/slides.rb
      lib/renderer.rb
      lib/player.rb
      lib/vtt_track.rb
      lib/slide.rb
      lib/deck.rb
      viewer/index.html
      viewer/presenter.html
      viewer/print.html
    ].freeze

    # ディレクトリごとコピーするもの(wasm + ブリッジ)。
    RUNTIME_DIRS = %w[vendor/lilac].freeze

    STARTER_DECK = <<~MD
      ---
      theme: default
      ---
      > [cover]

      # はじめての ことよみ

      #### ここにサブタイトル

      > [speaker]
      > 発表者ノートはこう書きます(発表中に n キーで開閉)。

      ---

      # つかいかた

      - `src/deck.md` を編集して保存する(`kotoyomi serve` 起動中は自動で反映)
      - 単発ビルドは `kotoyomi build`
      - 画像・音声は `src/assets/` に置く(参照は `assets/xxx`)
      - 音声同期スライドは ` ```vtt audio="assets/xxx.mp3" ` ブロックで作る

      ---
      > [section]

      # おわり
    MD

    def initialize(target, template_root:, stdout: $stdout, stderr: $stderr)
      @target = File.expand_path(target)
      @template_root = template_root
      @stdout = stdout
      @stderr = stderr
    end

    # 生成して 0 を返す。既存の非空ディレクトリには展開しない(1 を返す)。
    def generate
      if File.exist?(@target) && !empty_dir?(@target)
        @stderr.puts "kotoyomi: #{@target} は既に存在し空ではありません"
        return 1
      end

      copy_runtime
      FileUtils.mkdir_p(File.join(@target, "src", "assets"))
      FileUtils.mkdir_p(File.join(@target, "public", "viewer", "assets"))
      write(File.join(@target, "src", "deck.md"), STARTER_DECK)
      keep(File.join(@target, "src", "assets"))
      keep(File.join(@target, "public", "viewer", "assets"))
      0
    end

    private

    def empty_dir?(path)
      File.directory?(path) && Dir.children(path).empty?
    end

    def copy_runtime
      public_dir = File.join(@target, "public")
      RUNTIME_FILES.each do |rel|
        src = File.join(@template_root, rel)
        dst = File.join(public_dir, rel)
        FileUtils.mkdir_p(File.dirname(dst))
        FileUtils.cp(src, dst)
      end
      RUNTIME_DIRS.each do |rel|
        src = File.join(@template_root, rel)
        dst = File.join(public_dir, rel)
        FileUtils.mkdir_p(File.dirname(dst))
        FileUtils.cp_r(src, dst)
      end
    end

    def write(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end

    # 空ディレクトリも git に乗るよう .gitkeep を置く。
    def keep(dir)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, ".gitkeep"), "") unless Dir.children(dir).any?
    end
  end
end
