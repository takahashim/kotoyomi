# frozen_string_literal: true

class Kotoyomi::CLI
  module Renderer
    # RedQuilt::Renderer::HTML の内部 @out バッファに依存する操作を隔離。
    # RedQuilt が public な fragment rendering API を提供したら置き換える。
    module RedQuiltBufferSwap
      def render_fragment(node_ids)
        saved = @out
        @out = +""
        node_ids.each { |id| render_node(id) }
        @out
      ensure
        @out = saved
      end
    end

    # Common base for the slide renderers.
    class Base < RedQuilt::Renderer::HTML
      include RedQuiltBufferSwap
      def initialize(document, title: "", lang: "en")
        super(document)
        @title = title
        @lang = lang
        # Frontmatter (theme, etc.) is already parsed by red_quilt; it is nil
        # when absent, so normalize to {}.
        @meta = document.frontmatter || {}
      end

      def render
        raise NotImplementedError, "#{self.class} must implement #render"
      end

      private

      def slides
        @slides ||= Partitioner.new(@document).partition
      end

      # The per-slide fields shared by every renderer, with the slide's content
      # already rendered to an HTML fragment.
      def slide_views
        slides.map.with_index do |slide, index|
          view = {
            index: index,
            title: slide.title,
            html: render_fragment(slide.content_ids),
            speaker_notes: slide.speaker_notes,
            dynamic: slide.dynamic
          }
          block_given? ? view.merge(yield(slide)) : view
        end
      end
    end
  end
end
