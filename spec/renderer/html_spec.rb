RSpec.describe Kotoyomi::CLI::Renderer::HTML do
  def render_html(markdown, title: "Test", lang: "en")
    doc = RedQuilt.parse(markdown)
    Kotoyomi::CLI::Renderer::HTML.new(doc, title: title, lang: lang).render
  end

  describe "HTML structure" do
    it "includes DOCTYPE and html tag" do
      html = render_html("# Test\n\nContent")
      expect(html).to start_with("<!DOCTYPE html>\n")
      expect(html).to include('<html lang="en">')
    end

    it "sets title correctly" do
      html = render_html("# Test", title: "My Presentation")
      expect(html).to include("<title>My Presentation</title>")
    end

    it "sets lang attribute" do
      html = render_html("# Test", lang: "ja")
      expect(html).to include('<html lang="ja">')
    end

    it "includes CSS in head" do
      html = render_html("# Test\n\nContent")
      expect(html).to include("<style>")
      expect(html).to include(".slide")
      expect(html).to include(".slide-nav")
    end

    it "includes navigation buttons" do
      html = render_html("# Test")
      expect(html).to include(%(<button id="prev"))
      expect(html).to include(%(<button id="next"))
    end

    it "includes JavaScript" do
      html = render_html("# Test")
      expect(html).to include("<script>")
      expect(html).to include("let currentSlide = 0;")
    end
  end

  describe "slide content rendering" do
    it "renders headings" do
      html = render_html("# H1\n\n## H2")
      expect(html).to include("<h1>H1</h1>")
      expect(html).to include("<h2>H2</h2>")
    end

    it "renders paragraphs" do
      html = render_html("First para\n\nSecond para")
      expect(html).to include("<p>First para</p>")
      expect(html).to include("<p>Second para</p>")
    end

    it "renders lists" do
      html = render_html("- Item 1\n- Item 2")
      expect(html).to include("<ul>")
      expect(html).to include("<li>Item 1</li>")
    end
  end

  describe "blockquote extension handling" do
    it "excludes [speaker] blockquote from HTML" do
      html = render_html("# Slide\n\n> [speaker]\n> Speaker notes")
      expect(html).not_to include("Speaker notes")
      expect(html).not_to include("[speaker]")
    end

    it "excludes [dynamic] blockquote from HTML" do
      html = render_html("# Slide\n\n> [dynamic]")
      expect(html).not_to include("[dynamic]")
    end

    it "includes normal blockquotes in HTML" do
      html = render_html("# Slide\n\n> A normal quote")
      expect(html).to include("<blockquote>")
      expect(html).to include("A normal quote")
    end
  end

  describe "slide wrapping" do
    it "wraps each slide in section.slide" do
      html = render_html("# Slide 1\n\n---\n\n# Slide 2")
      expect(html).to include('<section class="slide active">')
      expect(html).to include('<section class="slide">')
      expect(html.scan(/<section class="slide/).length).to eq(2)
    end

    it "marks first slide as active" do
      html = render_html("# Slide 1\n\n---\n\n# Slide 2")
      lines = html.split("\n")
      first_slide_idx = lines.find_index { |l| l.include?('<section class="slide') }
      expect(lines[first_slide_idx]).to include("active")
    end
  end

  describe "HTML escaping" do
    it "escapes title" do
      html = render_html("# Test", title: "Title <script>")
      expect(html).to include("<title>Title &lt;script&gt;</title>")
    end

    it "escapes lang attribute" do
      html = render_html("# Test", lang: 'en" onload="alert')
      expect(html).not_to include('onload="alert')
    end
  end

  describe "JavaScript initialization" do
    it "sets correct total_slides in JS" do
      html = render_html("# Slide 1\n\n---\n\n# Slide 2\n\n---\n\n# Slide 3")
      expect(html).to include("const totalSlides = 3;")
    end

    it "includes keyboard event handling" do
      html = render_html("# Test")
      expect(html).to include("'ArrowRight'")
      expect(html).to include("'ArrowLeft'")
      expect(html).to include("e.key === ' '")
    end
  end
end
