# frozen_string_literal: true

class Kotoyomi::CLI
  module Renderer
    class HTML < Base
      def render
        build_html(slide_views)
      end

      private

      def build_html(slide_data)
        <<~HTML
          <!DOCTYPE html>
          <html lang="#{escape_html(@lang)}">
          <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>#{escape_html(@title)}</title>
          <style>
          #{Assets.css}</style>
          </head>
          <body>
          <div class="slide-deck">
          #{slides_html(slide_data)}</div>
          <div class="slide-nav">
          <button id="prev" aria-label="Previous slide">&larr;</button>
          <span id="counter"></span>
          <button id="next" aria-label="Next slide">&rarr;</button>
          </div>
          <script>
          #{Assets.js(slide_data.length)}</script>
          </body>
          </html>
        HTML
      end

      def slides_html(slide_data)
        slide_data.each_with_index.map do |slide, index|
          active = index.zero? ? " active" : ""
          %(<section class="slide#{active}">\n#{slide[:html]}</section>\n)
        end.join
      end
    end
  end
end
