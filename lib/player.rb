module Kotoyomi
  class Player
    def initialize(track, elements, audio)
      @track = track
      @elements = elements
      @audio = audio
      @cues = @track[:cues]
      @cue_count = @cues[:length].to_i
      @current_index = -1
      # cuechange listener の wrapper Value を保持。Player の寿命中は
      # GC されないように (JS::Object#on は wrapper を返すが
      # 呼び出し側で持たないと release される)
      @callbacks = []
    end

    def start
      @track[:mode] = "hidden"
      @callbacks << @track.on(:cuechange) { update }
      update
      self
    end

    private

    def update
      next_index = active_cue_index
      return if next_index == @current_index

      @elements[@current_index].remove_class("active") if @current_index >= 0
      @current_index = next_index
      @elements[next_index].add_class("active") if next_index >= 0
    end

    # 現在の audio.currentTime に対応する cue の index を返す。
    # track.activeCues に頼らず、cue の startTime / endTime から決定的に求める
    # (cuechange の初期発火タイミングの揺れに依存しないため)。
    def active_cue_index
      current_ms = (@audio[:currentTime].to_f * 1000).round
      @cue_count.times do |i|
        cue = @cues[i]
        start_ms = (cue[:startTime].to_f * 1000).round
        end_ms = (cue[:endTime].to_f * 1000).round
        return i if start_ms <= current_ms && current_ms < end_ms
      end
      -1
    end
  end
end
