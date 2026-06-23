# Pure-Ruby unit test for the slides.json intake (Kotoyomi::Slides.parse).
# Runs under plain MRI — no wasm, no Fetchy — because parse is deliberately
# JS-free. Run: ruby test/slides_test.rb
require "minitest/autorun"
require_relative "../lib/slides"

class SlidesParseTest < Minitest::Test
  DATA = {
    "metadata" => { "title" => "Demo", "total_slides" => 3, "reading_direction" => "vertical" },
    "slides" => [
      { "index" => 0, "title" => "Intro", "html" => "<h1>Intro</h1>",
        "layout" => nil, "speaker_notes" => nil, "dynamic" => false, "player" => nil },
      { "index" => 1, "title" => "Sakura", "html" => "<h1>Sakura</h1>",
        "layout" => nil, "speaker_notes" => nil, "dynamic" => false,
        "player" => { "audio" => "poems/sakura.mp3", "vtt" => "WEBVTT\n\n00:00.000 --> 00:00.500\nあさ\n",
                      "reading_direction" => "horizontal" } },
      { "index" => 2, "title" => "比較", "html" => "<h2>左</h2><h2>右</h2>",
        "layout" => "two-column", "regions" => ["<h2>左</h2>", "<h2>右</h2>"],
        "speaker_notes" => "ここで対比を強調", "dynamic" => false, "player" => nil },
    ],
  }

  def setup
    @rows = Kotoyomi::Slides.parse(DATA)
  end

  def test_row_count
    assert_equal 3, @rows.length
  end

  def test_non_player_slide_flattens_to_nil_audio_vtt
    assert_nil @rows[0]["audio"]
    assert_nil @rows[0]["vtt"]
    assert_equal "<h1>Intro</h1>", @rows[0]["html"]
    assert_equal 0, @rows[0]["index"]
  end

  def test_player_slide_flattens_audio_and_vtt
    assert_equal "poems/sakura.mp3", @rows[1]["audio"]
    assert_includes @rows[1]["vtt"], "WEBVTT"
    assert_includes @rows[1]["vtt"], "あさ"
  end

  def test_layout_and_notes_passthrough
    assert_nil @rows[0]["layout"]
    assert_nil @rows[0]["notes"]
    assert_equal "two-column", @rows[2]["layout"]
    assert_equal "ここで対比を強調", @rows[2]["notes"]
  end

  def test_regions_without_split_is_whole_html
    # No "regions" key → single region == html (no separator).
    assert_equal "<h1>Intro</h1>", @rows[0]["regions"]
    refute_includes @rows[0]["regions"], Kotoyomi::Slides::REGION_SEP
  end

  def test_regions_joined_with_separator_when_split
    parts = @rows[2]["regions"].split(Kotoyomi::Slides::REGION_SEP, -1)
    assert_equal ["<h2>左</h2>", "<h2>右</h2>"], parts
  end

  def test_reading_direction_vtt_overrides_frontmatter_default
    # 非プレイヤー/指定なし → frontmatter の既定(vertical)
    assert_equal "vertical", @rows[0]["reading_direction"]
    # vtt フェンスの指定があればそれが優先
    assert_equal "horizontal", @rows[1]["reading_direction"]
  end

  def test_keys_are_strings_for_data_each
    assert_equal %w[index title html layout regions notes audio vtt reading_direction].sort,
                 @rows[0].keys.sort
  end

  def test_handles_empty_and_nil
    assert_equal [], Kotoyomi::Slides.parse(nil)
    assert_equal [], Kotoyomi::Slides.parse({})
    assert_equal [], Kotoyomi::Slides.parse({ "slides" => [] })
  end
end
