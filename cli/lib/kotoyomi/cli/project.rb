# frozen_string_literal: true

class Kotoyomi::CLI
  # プロジェクトのディレクトリ規約を1箇所に集約した値オブジェクト。
  #
  #   <root>/src/         … 作者が書くもの(deck.md と素材 assets/)
  #   <root>/public/      … 配信する静的サイト(ランタイム + build 生成物)
  #
  # 規約(src/ と public/viewer/ の配置)を変えるときはここだけ直せば済むよう、
  # cli.rb / generator.rb / serve_command.rb はパスをすべて本クラス経由で得る。
  class Project
    attr_reader :root

    def initialize(root)
      @root = File.expand_path(root)
    end

    def deck_path = File.join(@root, "src", "deck.md")
    def assets_src = File.join(@root, "src", "assets")
    def public_dir = File.join(@root, "public")
    def viewer_dir = File.join(public_dir, "viewer")
    def slides_json_path = File.join(viewer_dir, "slides.json")
    def assets_dst = File.join(viewer_dir, "assets")

    def deck? = File.file?(deck_path)
    def public? = File.directory?(public_dir)
    def assets_src? = File.directory?(assets_src)
  end
end
