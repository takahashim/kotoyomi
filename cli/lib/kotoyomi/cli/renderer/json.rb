# frozen_string_literal: true

require "json"

class Kotoyomi::CLI
  module Renderer
    class JSON < Base
      def render
        slide_data = slide_views do |slide|
          {
            layout: slide.layout,
            # One rendered HTML string per content region (split layouts use
            # >1); Slide#content_regions handles the empty-region fallback.
            regions: slide.content_regions.map { |ids| render_fragment(ids) },
            player: slide.player
          }
        end
        ::JSON.pretty_generate(metadata: metadata(slide_data.length), slides: slide_data)
      end

      private

      def metadata(total_slides)
        meta = {}
        @meta.each { |k, v| meta[k.to_s] = v }
        meta["title"] = @title
        meta["language"] = @lang
        meta["total_slides"] = total_slides
        meta
      end
    end
  end
end
