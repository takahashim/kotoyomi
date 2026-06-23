RSpec.describe Kotoyomi::CLI::Partitioner do
  def parse_markdown(md)
    RedQuilt.parse(md)
  end

  describe "#partition" do
    it "splits slides on thematic breaks" do
      doc = parse_markdown("# Slide 1\n\nContent\n\n---\n\n# Slide 2\n\nMore")
      partitioner = Kotoyomi::CLI::Partitioner.new(doc)
      slides = partitioner.partition
      expect(slides.length).to eq(2)
      expect(slides[0][:title]).to eq("Slide 1")
      expect(slides[1][:title]).to eq("Slide 2")
    end

    it "creates single slide without breaks" do
      doc = parse_markdown("# Title\n\nContent")
      partitioner = Kotoyomi::CLI::Partitioner.new(doc)
      slides = partitioner.partition
      expect(slides.length).to eq(1)
      expect(slides[0][:title]).to eq("Title")
    end

    it "ignores empty slides from consecutive breaks" do
      doc = parse_markdown("# Slide 1\n\n---\n\n---\n\n# Slide 2")
      partitioner = Kotoyomi::CLI::Partitioner.new(doc)
      slides = partitioner.partition
      expect(slides.length).to eq(2)
    end

    it "ignores breaks at start and end" do
      doc = parse_markdown("---\n\n# Slide\n\n---")
      partitioner = Kotoyomi::CLI::Partitioner.new(doc)
      slides = partitioner.partition
      expect(slides.length).to eq(1)
    end

    it "detects [speaker] blockquote" do
      doc = parse_markdown("# Slide\n\nContent\n\n> [speaker]\n> Speaker notes here")
      partitioner = Kotoyomi::CLI::Partitioner.new(doc)
      slides = partitioner.partition
      expect(slides[0][:speaker_notes]).to include("Speaker notes here")
    end

    it "removes [speaker] line from notes" do
      doc = parse_markdown("# Slide\n\n> [speaker]\n> Line 1\n> Line 2")
      partitioner = Kotoyomi::CLI::Partitioner.new(doc)
      slides = partitioner.partition
      notes = slides[0][:speaker_notes]
      expect(notes).not_to include("[speaker]")
      expect(notes).to include("Line 1")
    end

    it "detects [dynamic] blockquote" do
      doc = parse_markdown("# Slide\n\n> [dynamic]")
      partitioner = Kotoyomi::CLI::Partitioner.new(doc)
      slides = partitioner.partition
      expect(slides[0][:dynamic]).to be true
    end

    it "defaults dynamic to false" do
      doc = parse_markdown("# Slide\n\nContent")
      partitioner = Kotoyomi::CLI::Partitioner.new(doc)
      slides = partitioner.partition
      expect(slides[0][:dynamic]).to be false
    end

    it "extracts title from first heading" do
      doc = parse_markdown("# My Title\n\nContent")
      partitioner = Kotoyomi::CLI::Partitioner.new(doc)
      slides = partitioner.partition
      expect(slides[0][:title]).to eq("My Title")
    end

    it "handles multiple blockquotes (only first [speaker] is special)" do
      md = "# Slide\n\n> [speaker]\n> Note\n\n> Regular quote"
      doc = parse_markdown(md)
      partitioner = Kotoyomi::CLI::Partitioner.new(doc)
      slides = partitioner.partition
      expect(slides[0][:speaker_notes]).to eq("Note")
      # Regular blockquote should be in content_ids
      expect(slides[0][:content_ids].length).to be > 0
    end

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

    it "extracts ```vtt block into player config" do
      slides = Kotoyomi::CLI::Partitioner.new(parse_markdown(player_md)).partition
      expect(slides[0][:player]).to eq(
        audio: "poems/sample.mp3",
        vtt: "WEBVTT\n\n00:00.000 --> 00:00.500\nあさ\n",
        reading_direction: nil
      )
    end

    it "reads reading_direction from the vtt fence" do
      md = "```vtt audio=\"a.mp3\" reading_direction=\"horizontal\"\nWEBVTT\n\n00:00.000 --> 00:01.000\nx\n```"
      slides = Kotoyomi::CLI::Partitioner.new(parse_markdown(md)).partition
      expect(slides[0][:player][:reading_direction]).to eq("horizontal")
    end

    it "does not add the ```vtt block to content_ids" do
      slides = Kotoyomi::CLI::Partitioner.new(parse_markdown(player_md)).partition
      # Only the heading remains as rendered content.
      expect(slides[0][:content_ids].length).to eq(1)
      expect(slides[0][:title]).to eq("Sakura")
    end

    it "defaults player to nil" do
      slides = Kotoyomi::CLI::Partitioner.new(parse_markdown("# Slide\n\nContent")).partition
      expect(slides[0][:player]).to be_nil
    end

    it "keeps a player-only slide (no other content)" do
      md = "```vtt audio=\"a.mp3\"\nWEBVTT\n\n00:00.000 --> 00:01.000\nx\n```"
      slides = Kotoyomi::CLI::Partitioner.new(parse_markdown(md)).partition
      expect(slides.length).to eq(1)
      expect(slides[0][:player][:audio]).to eq("a.mp3")
    end

    it "treats a plain code block (non-vtt) as normal content" do
      md = "# S\n\n```ruby\nputs 1\n```"
      slides = Kotoyomi::CLI::Partitioner.new(parse_markdown(md)).partition
      expect(slides[0][:player]).to be_nil
      expect(slides[0][:content_ids].length).to eq(2)
    end

    it "defaults layout to nil" do
      slides = Kotoyomi::CLI::Partitioner.new(parse_markdown("# Slide")).partition
      expect(slides[0][:layout]).to be_nil
    end

    it "detects [cover] / [section] / [subsection] shorthand layout tags" do
      cover = Kotoyomi::CLI::Partitioner.new(parse_markdown("> [cover]\n\n# Title")).partition
      section = Kotoyomi::CLI::Partitioner.new(parse_markdown("> [section]\n\n# Ch.1")).partition
      sub = Kotoyomi::CLI::Partitioner.new(parse_markdown("> [subsection]\n\n# 1.1")).partition
      expect(cover[0][:layout]).to eq("cover")
      expect(section[0][:layout]).to eq("section")
      expect(sub[0][:layout]).to eq("subsection")
    end

    it "detects [layout: X] generic tag (value lowercased)" do
      slides = Kotoyomi::CLI::Partitioner.new(parse_markdown("> [layout: Two-Column]\n\n# T")).partition
      expect(slides[0][:layout]).to eq("two-column")
    end

    it "leaves an unknown [tag] blockquote as content" do
      slides = Kotoyomi::CLI::Partitioner.new(parse_markdown("# S\n\n> [1] a reference")).partition
      expect(slides[0][:layout]).to be_nil
      expect(slides[0][:content_ids].length).to eq(2)
    end

    it "keeps a single region by default" do
      slides = Kotoyomi::CLI::Partitioner.new(parse_markdown("# S\n\nA\n\nB")).partition
      expect(slides[0][:regions].length).to eq(1)
      expect(slides[0][:regions].first.length).to eq(3)
    end

    it "splits content into regions on [column] / [split]" do
      md = "# S\n\nleft\n\n> [column]\n\nright"
      slides = Kotoyomi::CLI::Partitioner.new(parse_markdown(md)).partition
      expect(slides[0][:regions].length).to eq(2)
      expect(slides[0][:content_ids].length).to eq(3) # heading + 2 paragraphs

      split = Kotoyomi::CLI::Partitioner.new(parse_markdown("a\n\n> [split]\n\nb")).partition
      expect(split[0][:regions].length).to eq(2)
    end
  end
end
