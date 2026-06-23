# frozen_string_literal: true

class Kotoyomi::CLI
  class Partitioner
    # RedQuilt 内部 API(arena)への依存を1箇所に閉じ込める。document インスタンスに
    # fence_info / node_text を追加し、クラス全体はこれ経由でアクセスする。
    # RedQuilt が public API を提供したらこの prepend は削除できる。
    module ArenaAccess
      def fence_info(node_id)
        arena.str2(node_id).to_s
      end

      def node_text(node_id)
        arena.text(node_id).to_s
      end
    end

    def initialize(document)
      @document = document
      @document.singleton_class.prepend(ArenaAccess) unless @document.respond_to?(:fence_info)
    end

    # Returns an Array of Kotoyomi::CLI::Slide.
    #
    # Region grouping: a slide's content is split into regions by a
    # `> [column]` (alias `> [split]`) marker. Most slides have a single
    # region; multi-region slides drive split layouts (two-column, ...).
    def partition
      slides = [Slide.blank]

      @document.root.children.each do |node|
        if node.type == :thematic_break
          slides << Slide.blank
          next
        end

        slide = slides.last

        if (player = player_block(node))
          # A ```vtt code block carries the audio-sync player config; it is
          # extracted here and intentionally NOT added to content_ids, so it
          # does not render as a literal code listing.
          slide.player = player
          next
        end

        directive = parse_directive(node)
        case directive && directive.first
        when :speaker
          slide.speaker_notes = extract_notes(node)
        when :dynamic
          slide.dynamic = true
        when :region
          # Start a new content region (e.g. the right column).
          slide.regions << []
        when :layout
          slide.layout = directive.last
        else
          slide.content_ids << node.node_id
          slide.regions.last << node.node_id
          slide.title = node.text if slide.title.nil? && node.type == :heading
        end
      end

      slides.reject(&:empty?)
    end

    private

    # Detects a ` ```vtt audio="..." ` fenced code block and returns
    # { audio:, vtt:, reading_direction: }; nil for any other node. The fence
    # body is plain WebVTT (timing + text), rendered as the synced content.
    def player_block(node)
      return nil unless node.type == :code_block

      info = @document.fence_info(node.node_id)
      return nil unless info.split.first == "vtt"

      attrs = parse_fence_attrs(info)
      {
        audio: attrs["audio"],
        vtt: @document.node_text(node.node_id),
        # 縦書き/横書き。そのスライドだけの上書き(無ければ frontmatter 既定)。
        reading_direction: attrs["reading_direction"]
      }
    end

    # Parses `key="value"` pairs from a fence info string (e.g.
    # `vtt audio="poems/sample.mp3"`). Returns a String-keyed Hash.
    def parse_fence_attrs(info)
      info.scan(/(\w[\w-]*)="([^"]*)"/).to_h
    end

    # Recognizes a leading `[tag]` directive in a blockquote. Returns a
    # descriptor array (or nil for a normal content blockquote / non-quote):
    #   [speaker]         -> [:speaker]
    #   [dynamic]         -> [:dynamic]
    #   [column] [split]  -> [:region]
    #   [cover] [section] [subsection] -> [:layout, "cover"]
    #   [layout: X]       -> [:layout, "x"]   (also `[layout X]`)
    # Unknown `[tag]` blockquotes are left as content (return nil), so the
    # vocabulary stays conservative and authored `> [n] ...` quotes survive.
    def parse_directive(node)
      return nil unless node.type == :blockquote

      m = node.text.strip.match(/\A\[([^\]]+)\]/)
      return nil unless m

      key, _, rest = m[1].strip.partition(/[:\s]/)
      case key.downcase
      when "speaker"          then [:speaker]
      when "dynamic"          then [:dynamic]
      when "column", "split"  then [:region]
      when "cover", "section", "subsection" then [:layout, key.downcase]
      when "layout"
        value = rest.strip.downcase
        value.empty? ? nil : [:layout, value]
      end
    end

    def extract_notes(node)
      text = node.text.strip
      # Remove "[speaker]" and any surrounding whitespace/newline
      text.sub(/\A\[speaker\]\s*/, "").strip
    end
  end
end
