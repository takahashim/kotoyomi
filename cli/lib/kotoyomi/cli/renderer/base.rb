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

      # Render a set of content node ids to an HTML fragment.
      def render_fragment(node_ids)
        with_fresh_buffer do
          node_ids.each { |node_id| render_node(node_id) }
        end
      end

      # Swap in a clean output buffer for the duration of the block, returning
      # what was accumulated and restoring the previous buffer (even on error).
      # Isolates our dependency on RedQuilt's internal `@out` accumulator here.
      def with_fresh_buffer
        saved_out = @out
        @out = +""
        yield
        @out
      ensure
        @out = saved_out
      end
    end
  end
end
