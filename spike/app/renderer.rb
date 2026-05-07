# Ported from lib/renderer.rb. Differences:
#  - `require "js"` removed.
#  - `cue[:startTime]` is a JS Value (number); pass directly to data= which
#    coerces via `.to_s` — works because Value#to_s reads the JS string form.

module Kotoyomi
  class Renderer
    def initialize(cues, container)
      @cues = cues
      @container = container
    end

    def render
      @container.clear
      stanzas = each_cue.with_index.map { |cue, i| build_stanza(cue, i) }
      stanzas.each { |stanza| @container.append(stanza) }
      stanzas
    end

    private

    def each_cue
      return enum_for(:each_cue) unless block_given?

      @cues[:length].to_i.times { |i| yield @cues[i] }
    end

    def build_stanza(cue, index)
      cue_id = cue[:id].to_s
      stanza_id = cue_id.empty? ? "stanza-#{index + 1}" : cue_id

      DOM.create(:div, id: stanza_id, class: "stanza", data: { startTime: cue[:startTime] }) do |div|
        cue[:text].to_s.split("\n").each do |line|
          div.append(DOM.create(:p, class: "stanza-line", text: line))
        end
      end
    end
  end
end
