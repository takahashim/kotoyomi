module Kotoyomi
  # 再生位置から「いま光らせるべき連の index」を求めるだけの純ロジック。
  # 状態保持や DOM 操作・listener 管理は Lilac::Component 側 (signal / bind /
  # 自動 cleanup) が担うので、ここはフレームワーク非依存のドメインロジックに
  # 徹する。
  class Player
    def initialize(cues, audio)
      @cues = cues
      @cue_count = cues[:length].to_i
      @audio = audio
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
