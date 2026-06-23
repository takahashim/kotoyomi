# frozen_string_literal: true

class Kotoyomi::CLI
  # Markdown ソース → 出力文字列(HTML / JSON)への変換。frontmatter と CLI
  # オプションのマージ規則(title / lang の優先順位)もここに閉じる。単発変換
  # モード(run_legacy)とプロジェクトビルド(ProjectBuilder)の両方がこれを使う。
  #
  # ProjectBuilder へは renderer(`#call(source) -> String`)として丸ごと注入する。
  class Converter
    def initialize(format:, title: nil, auto_title: false, lang: nil)
      @format = format
      @title = title
      @auto_title = auto_title
      @lang = lang
    end

    # JSON は末尾に改行を付け、従来の puts 相当の出力に揃える。frontmatter は
    # red_quilt(`frontmatter: true`)が本文から剥がして `doc.frontmatter` に出す。
    def call(source)
      doc = RedQuilt.parse(source, frontmatter: true)
      case @format
      when :html then render(Renderer::HTML, doc)
      when :json then "#{render(Renderer::JSON, doc)}\n"
      end
    end

    private

    def render(renderer_class, doc)
      renderer_class.new(doc, title: title_for(doc), lang: lang_for(doc)).render
    end

    # title / lang は CLI オプション → frontmatter → 既定 の順で優先。title は
    # --auto-title 指定時のみ、他がなければ最初の見出しを既定に使う。
    def title_for(doc)
      front = doc.frontmatter || {}
      title = @title || front["title"]
      title = doc.first_heading_text.to_s if title.nil? && @auto_title
      title.to_s
    end

    def lang_for(doc)
      front = doc.frontmatter || {}
      (@lang || front["lang"] || front["language"] || DEFAULT_LANG).to_s
    end
  end
end
