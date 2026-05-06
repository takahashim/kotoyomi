require "js"

module Kotoyomi
  module Renderer
    def self.render(cues, container)
      document = JS.global[:document]
      container[:innerHTML] = ""

      elements = JS.eval("return [];")
      cue_count = cues[:length].to_i
      cue_count.times do |i|
        cue = cues[i]
        div = document.createElement("div")
        cue_id = cue[:id].to_s
        div[:id] = cue_id.empty? ? "stanza-#{i + 1}" : cue_id
        div[:className] = "stanza"
        div[:dataset][:startTime] = cue[:startTime].to_s

        cue[:text].to_s.split("\n").each do |line|
          p = document.createElement("p")
          p[:className] = "stanza-line"
          p[:textContent] = line
          div.appendChild(p)
        end

        container.appendChild(div)
        elements.push(div)
      end
      elements
    end
  end
end
