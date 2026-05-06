require "js"

module Kotoyomi
  class Player
    def initialize(track, elements)
      @track = track
      @elements = elements
      @cues = @track[:cues]
      @cue_count = @cues[:length].to_i
      @current_index = -1

      @track[:mode] = "hidden"
      @track.addEventListener("cuechange") { update }
      update
    end

    private

    def update
      active = @track[:activeCues]
      return if active.nil?

      next_index = active[:length].to_i > 0 ? find_index(active[0]) : -1
      return if next_index == @current_index

      @elements[@current_index].remove_class("active") if @current_index >= 0
      @current_index = next_index
      @elements[next_index].add_class("active") if next_index >= 0
    end

    def find_index(cue)
      start = cue[:startTime].to_f
      @cue_count.times do |i|
        return i if @cues[i][:startTime].to_f == start
      end
      -1
    end
  end
end
