module Kotoyomi
  # WebVTT cue 群を、Lilac の data-each に渡すデータモデルへ変換する純ロジック。
  # DOM には一切触れない (描画は HTML 側の data-each ディレクティブが担う)。
  #
  # 返す形:
  #   [{ "id" => "c1",
  #      "lines" => [{ "n" => 0, "text" => "あさ" }, { "n" => 1, "text" => "ゆきが" }] },
  #    ...]
  #
  # active 状態 (どの連を光らせるか) はここでは持たない。App 側で各連に
  # Signal を足し、再生位置に応じて flip する。
  class Renderer
    def initialize(cues)
      @cues = cues
    end

    def to_stanzas
      each_cue.with_index.map do |cue, index|
        cue_id = cue[:id].to_s
        stanza_id = cue_id.empty? ? "stanza-#{index + 1}" : cue_id
        { "id" => stanza_id, "lines" => to_lines(cue) }
      end
    end

    private

    def each_cue
      return enum_for(:each_cue) unless block_given?

      @cues[:length].to_i.times { |i| yield @cues[i] }
    end

    def to_lines(cue)
      cue[:text].to_s.split("\n").each_with_index.map do |line, n|
        { "n" => n, "text" => line }
      end
    end
  end
end
