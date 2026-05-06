require "js"

module Kotoyomi
  class Renderer
    def initialize(cues, container)
      @cues = cues
      @container = container
      @document = JS.global[:document]
    end

    def render
      @container[:innerHTML] = ""
      elements = JS.eval("return [];")
      @cues[:length].to_i.times do |i|
        elements.push(build_stanza(@cues[i], i))
      end
      elements
    end

    private

    def build_stanza(cue, index)
      div = @document.createElement("div")
      cue_id = cue[:id].to_s
      div[:id] = cue_id.empty? ? "stanza-#{index + 1}" : cue_id
      div[:className] = "stanza"
      div[:dataset][:startTime] = cue[:startTime].to_s

      cue[:text].to_s.split("\n").each do |line|
        p = @document.createElement("p")
        p[:className] = "stanza-line"
        p[:textContent] = line
        div.appendChild(p)
      end

      @container.appendChild(div)
      div
    end
  end
end
