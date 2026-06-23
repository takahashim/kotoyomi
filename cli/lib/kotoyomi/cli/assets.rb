# frozen_string_literal: true

class Kotoyomi::CLI
  # Static deck assets (CSS/JS) shipped alongside the gem. Kept out of the
  # renderer so styling can evolve without touching structure-generation code.
  module Assets
    DIR = File.join(__dir__, "assets")

    # Number of slides is injected into the player at render time.
    TOTAL_SLIDES_PLACEHOLDER = "__TOTAL_SLIDES__"

    class << self
      def css
        read("deck.css")
      end

      def js(total_slides)
        read("deck.js").sub(TOTAL_SLIDES_PLACEHOLDER, total_slides.to_s)
      end

      private

      def read(name)
        (@cache ||= {})[name] ||= File.read(File.join(DIR, name))
      end
    end
  end
end
