module Kotoyomi
  # slides.json (rqslides --format json の出力) を取り込む唯一の入口。
  #
  # 契約 JSON:
  #   { "metadata": {...},
  #     "slides": [ { "index", "title", "html", "layout", "regions",
  #                   "speaker_notes", "dynamic",
  #                   "player": { "audio", "vtt" } | null }, ... ] }
  #
  # これを data-each / props auto-fill に渡せる「String キーの行 hash の配列」へ
  # 正規化する。player は audio/vtt に平坦化し、非プレイヤースライドでは nil。
  #
  # regions(分割レイアウト用の領域ごとの HTML)は REGION_SEP 連結の 1 文字列に
  # する。props は DOM 属性経由の文字列で配列をそのまま渡せず、かつ mruby には
  # JSON が無いため。Slide 側が REGION_SEP で split して領域配列に戻す。
  #
  # `parse` は純 Ruby(JS にも Fetchy にも触れない)なのでホスト/CI で単体テスト可能。
  # 取得は各 deck が `Fetchy.json("slides.json")` で行い、その data を parse する
  # (metadata.theme などは deck 側で使う)。
  module Slides
    # 領域区切りセンチネル。HTML 本文にまず出現しない一意なコメント。
    REGION_SEP = "<!--rqslides:region-->".freeze

    # data: Fetchy.json が返す Ruby ネイティブ hash(String キー)。
    # 返り値: [{ "index","title","html","layout","regions","notes",
    #            "audio"|nil,"vtt"|nil }, ...]
    def self.parse(data)
      list = (data && data["slides"]) || []
      meta = (data && data["metadata"]) || {}
      default_reading = meta["reading_direction"]
      list.map do |slide|
        player = slide["player"]
        {
          "index"   => slide["index"],
          "title"   => slide["title"],
          "html"    => slide["html"].to_s,
          "layout"  => slide["layout"],
          "regions" => regions_string(slide),
          "notes"   => slide["speaker_notes"],
          "audio"   => player && player["audio"],
          "vtt"     => player && player["vtt"],
          # 縦書き/横書き。vtt フェンスの指定が優先、無ければ frontmatter の既定。
          "reading_direction" => (player && player["reading_direction"]) || default_reading,
        }
      end
    end

    # rqslides の regions(描画済み HTML の配列)を REGION_SEP 連結の 1 文字列に。
    # regions が無ければ html 全体を単一領域として返す。
    def self.regions_string(slide)
      regions = slide["regions"]
      regions = [slide["html"].to_s] unless regions.is_a?(Array) && !regions.empty?
      regions.map(&:to_s).join(REGION_SEP)
    end
  end
end
