RSpec.describe Kotoyomi::CLI::Renderer::JSON do
  def render_json(markdown, title: "Test", lang: "en")
    doc = RedQuilt.parse(markdown)
    Kotoyomi::CLI::Renderer::JSON.new(doc, title: title, lang: lang).render
  end

  def parse_json(markdown, **opts)
    require "json"
    JSON.parse(render_json(markdown, **opts))
  end

  describe "JSON structure" do
    it "outputs valid JSON" do
      json_str = render_json("# Test\n\nContent")
      expect { JSON.parse(json_str) }.not_to raise_error
    end

    it "includes metadata" do
      data = parse_json("# Test")
      expect(data["metadata"]).to be_a(Hash)
      expect(data["metadata"]).to have_key("title")
      expect(data["metadata"]).to have_key("language")
      expect(data["metadata"]).to have_key("total_slides")
    end

    it "includes slides array" do
      data = parse_json("# Slide 1\n\n---\n\n# Slide 2")
      expect(data["slides"]).to be_an(Array)
      expect(data["slides"].length).to eq(2)
    end

    it "sets metadata title" do
      data = parse_json("# Test", title: "My Title")
      expect(data["metadata"]["title"]).to eq("My Title")
    end

    it "sets metadata language" do
      data = parse_json("# Test", lang: "ja")
      expect(data["metadata"]["language"]).to eq("ja")
    end

    it "sets metadata total_slides" do
      data = parse_json("# Slide 1\n\n---\n\n# Slide 2")
      expect(data["metadata"]["total_slides"]).to eq(2)
    end
  end

  describe "slide objects" do
    it "includes index, title, html, speaker_notes, dynamic" do
      data = parse_json("# Slide 1\n\nContent")
      slide = data["slides"][0]
      expect(slide).to have_key("index")
      expect(slide).to have_key("title")
      expect(slide).to have_key("html")
      expect(slide).to have_key("speaker_notes")
      expect(slide).to have_key("dynamic")
    end

    it "sets correct index values" do
      data = parse_json("# Slide 1\n\n---\n\n# Slide 2\n\n---\n\n# Slide 3")
      expect(data["slides"][0]["index"]).to eq(0)
      expect(data["slides"][1]["index"]).to eq(1)
      expect(data["slides"][2]["index"]).to eq(2)
    end

    it "extracts title from heading" do
      data = parse_json("# My Title\n\nContent")
      expect(data["slides"][0]["title"]).to eq("My Title")
    end

    it "includes HTML content" do
      data = parse_json("# Slide\n\nContent")
      html = data["slides"][0]["html"]
      expect(html).to include("<h1>Slide</h1>")
      expect(html).to include("<p>Content</p>")
    end

    it "sets speaker_notes from [speaker] blockquote" do
      data = parse_json("# Slide\n\n> [speaker]\n> Speaker notes")
      expect(data["slides"][0]["speaker_notes"]).to include("Speaker notes")
    end

    it "sets speaker_notes to null when missing" do
      data = parse_json("# Slide\n\nContent")
      expect(data["slides"][0]["speaker_notes"]).to be_nil
    end

    it "sets dynamic to true when [dynamic] blockquote present" do
      data = parse_json("# Slide\n\n> [dynamic]")
      expect(data["slides"][0]["dynamic"]).to be true
    end

    it "sets dynamic to false by default" do
      data = parse_json("# Slide\n\nContent")
      expect(data["slides"][0]["dynamic"]).to be false
    end

    it "includes layout and regions keys" do
      slide = parse_json("# Slide\n\nContent")["slides"][0]
      expect(slide).to have_key("layout")
      expect(slide).to have_key("regions")
    end

    it "defaults layout to null and regions to a single region" do
      slide = parse_json("# Slide\n\nContent")["slides"][0]
      expect(slide["layout"]).to be_nil
      expect(slide["regions"]).to be_an(Array)
      expect(slide["regions"].length).to eq(1)
      expect(slide["regions"][0]).to include("<h1>Slide</h1>")
    end

    it "emits the named layout" do
      slide = parse_json("> [layout: two-column]\n\n# T")["slides"][0]
      expect(slide["layout"]).to eq("two-column")
    end

    it "splits regions on [column] (each its own rendered HTML)" do
      slide = parse_json("## Left\n\nL\n\n> [column]\n\n## Right\n\nR")["slides"][0]
      expect(slide["regions"].length).to eq(2)
      expect(slide["regions"][0]).to include("Left")
      expect(slide["regions"][0]).not_to include("Right")
      expect(slide["regions"][1]).to include("Right")
    end
  end

  describe "blockquote extension handling" do
    it "removes [speaker] blockquote from HTML" do
      data = parse_json("# Slide\n\n> [speaker]\n> Notes")
      html = data["slides"][0]["html"]
      expect(html).not_to include("Notes")
      expect(html).not_to include("[speaker]")
    end

    it "removes [dynamic] blockquote from HTML" do
      data = parse_json("# Slide\n\n> [dynamic]")
      html = data["slides"][0]["html"]
      expect(html).not_to include("[dynamic]")
    end

    it "includes normal blockquotes in HTML" do
      data = parse_json("# Slide\n\n> A quote")
      html = data["slides"][0]["html"]
      expect(html).to include("<blockquote>")
      expect(html).to include("A quote")
    end
  end

  describe "player (```vtt) handling" do
    let(:player_md) do
      <<~MD
        # Sakura

        ```vtt audio="poems/sample.mp3"
        WEBVTT

        00:00.000 --> 00:00.500
        あさ
        ```
      MD
    end

    it "includes a player field with audio and vtt" do
      data = parse_json(player_md)
      player = data["slides"][0]["player"]
      expect(player["audio"]).to eq("poems/sample.mp3")
      expect(player["vtt"]).to include("WEBVTT")
      expect(player["vtt"]).to include("あさ")
    end

    it "sets player to null for non-player slides" do
      data = parse_json("# Slide\n\nContent")
      expect(data["slides"][0]["player"]).to be_nil
    end

    it "does not render the vtt body into HTML" do
      data = parse_json(player_md)
      html = data["slides"][0]["html"]
      expect(html).to include("<h1>Sakura</h1>")
      expect(html).not_to include("WEBVTT")
      expect(html).not_to include("あさ")
      expect(html).not_to include("00:00.000")
    end
  end

  describe "multiple slides" do
    it "handles multiple slides with different attributes" do
      md = "# Slide 1\n\n> [speaker]\n> Note 1\n\n---\n\n# Slide 2\n\n> [dynamic]\n\n---\n\n# Slide 3"
      data = parse_json(md)
      expect(data["slides"].length).to eq(3)
      expect(data["slides"][0]["speaker_notes"]).to eq("Note 1")
      expect(data["slides"][0]["dynamic"]).to be false
      expect(data["slides"][1]["speaker_notes"]).to be_nil
      expect(data["slides"][1]["dynamic"]).to be true
      expect(data["slides"][2]["speaker_notes"]).to be_nil
      expect(data["slides"][2]["dynamic"]).to be false
    end
  end
end
