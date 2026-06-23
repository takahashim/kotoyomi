# frozen_string_literal: true

require "fileutils"

class Kotoyomi::CLI
  # src/deck.md → public/viewer/slides.json を生成し、src/assets を viewer 配下へ
  # 同期する。Markdown→JSON 変換そのものは持たず、`renderer`(Markdown 文字列を
  # 受け JSON 文字列を返す callable)に委譲する ─ 変換パイプラインはレガシー単発
  # モードと共有したいので CLI 側に置き、ここはファイル I/O の責務に絞る。
  class ProjectBuilder
    def initialize(project, renderer:, stdout:, stderr:)
      @project = project
      @renderer = renderer
      @stdout = stdout
      @stderr = stderr
    end

    # 成功時 0、deck.md 不在時 1。
    def build
      unless @project.deck?
        @stderr.puts "kotoyomi: #{@project.deck_path} が見つかりません(kotoyomi new で作成、またはプロジェクト直下で実行)"
        return 1
      end

      FileUtils.mkdir_p(@project.viewer_dir)
      File.write(@project.slides_json_path, @renderer.call(File.read(@project.deck_path)))
      sync_assets
      @stdout.puts "kotoyomi: built public/viewer/slides.json"
      0
    end

    private

    # src/assets/* を public/viewer/assets/ へコピー(画像 / VTT の audio="assets/…" 解決用)。
    def sync_assets
      return unless @project.assets_src?

      FileUtils.mkdir_p(@project.assets_dst)
      Dir.children(@project.assets_src).each do |entry|
        next if entry == ".gitkeep"

        FileUtils.cp_r(File.join(@project.assets_src, entry), @project.assets_dst)
      end
    end
  end
end
