# frozen_string_literal: true

class Kotoyomi::CLI
  module Renderer
    # Common base for the slide renderers.
    class Base < RedQuilt::Renderer::HTML
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
