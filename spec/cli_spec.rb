require "stringio"
require "tempfile"
require "kotoyomi/cli"

RSpec.describe Kotoyomi::CLI do
  def run(argv, input: "")
    stdin = StringIO.new(input)
    stdout = StringIO.new
    stderr = StringIO.new
    code = Kotoyomi::CLI.run(argv.dup, stdin: stdin, stdout: stdout, stderr: stderr)
    [code, stdout.string, stderr.string]
  end

  describe "default invocation (HTML output)" do
    it "renders HTML by default" do
      code, out, _ = run([], input: "# Hello\n\nContent\n")
      expect(code).to eq(0)
      expect(out).to start_with("<!DOCTYPE html>\n")
      expect(out).to include("<section class=\"slide")
      expect(out).to include("Hello")
    end
  end

  describe "--format option" do
    it "outputs HTML when --format html is given" do
      code, out, _ = run(["--format", "html"], input: "# Slide 1\n\n---\n\n# Slide 2\n")
      expect(code).to eq(0)
      expect(out).to start_with("<!DOCTYPE html>")
      expect(out.scan(/<section class="slide/).length).to eq(2)
    end

    it "outputs JSON when --format json is given" do
      code, out, _ = run(["--format", "json"], input: "# Test\n\nContent\n")
      expect(code).to eq(0)
      require "json"
      data = JSON.parse(out)
      expect(data).to be_a(Hash)
      expect(data["metadata"]).to be_a(Hash)
      expect(data["slides"]).to be_an(Array)
    end

    it "rejects unknown format values" do
      code, _, err = run(["--format", "xml"], input: "")
      expect(code).to eq(1)
      expect(err).to include("invalid argument")
    end
  end

  describe "title options" do
    it "uses --title for the document title" do
      code, out, _ = run(["--title", "My Presentation"], input: "# Test\n")
      expect(code).to eq(0)
      expect(out).to include("<title>My Presentation</title>")
    end

    it "derives title from first heading with --auto-title" do
      code, out, _ = run(["--auto-title"], input: "# My Title\n\nContent\n")
      expect(code).to eq(0)
      expect(out).to include("<title>My Title</title>")
    end

    it "prefers explicit --title over --auto-title" do
      code, out, _ = run(["--auto-title", "--title", "Explicit"], input: "# First\n\nContent\n")
      expect(code).to eq(0)
      expect(out).to include("<title>Explicit</title>")
      expect(out).not_to include("<title>First</title>")
    end
  end

  describe "--lang option" do
    it "sets html lang attribute" do
      code, out, _ = run(["--lang", "ja"], input: "# Test\n")
      expect(code).to eq(0)
      expect(out).to include('<html lang="ja">')
    end

    it "defaults to en" do
      code, out, _ = run([], input: "# Test\n")
      expect(code).to eq(0)
      expect(out).to include('<html lang="en">')
    end
  end

  describe "file input" do
    it "reads from FILE when given" do
      Tempfile.open(["rqslides", ".md"]) do |f|
        f.write("# File Test\n\nContent\n")
        f.flush
        code, out, _ = run([f.path])
        expect(code).to eq(0)
        expect(out).to include("File Test")
      end
    end

    it "exits with 1 when FILE doesn't exist" do
      code, _, err = run(["/no/such/path"])
      expect(code).to eq(1)
      expect(err).to include("no such file")
    end

    it "exits with 1 when too many arguments given" do
      code, _, err = run(["a.md", "b.md"])
      expect(code).to eq(1)
      expect(err).to include("too many arguments")
    end
  end

  describe "--help and --version" do
    it "prints help and exits 0 with --help" do
      code, _, err = run(["--help"])
      expect(code).to eq(0)
      expect(err).to include("Usage:")
    end

    it "prints version with --version" do
      code, _, err = run(["--version"])
      expect(code).to eq(0)
      expect(err).to include(Kotoyomi::CLI::VERSION)
    end
  end

  describe "slide partitioning via CLI" do
    it "splits slides on thematic breaks" do
      code, out, _ = run([], input: "# Slide 1\n\n---\n\n# Slide 2\n")
      expect(code).to eq(0)
      expect(out.scan(/<section class="slide/).length).to eq(2)
    end

    it "handles [speaker] blockquotes" do
      code, out, _ = run(["--format", "json"], input: "# Slide\n\n> [speaker]\n> Notes")
      expect(code).to eq(0)
      require "json"
      data = JSON.parse(out)
      expect(data["slides"][0]["speaker_notes"]).to include("Notes")
    end

    it "handles [dynamic] blockquotes" do
      code, out, _ = run(["--format", "json"], input: "# Slide\n\n> [dynamic]")
      expect(code).to eq(0)
      require "json"
      data = JSON.parse(out)
      expect(data["slides"][0]["dynamic"]).to be true
    end
  end

  describe "--output option" do
    it "writes to the file instead of stdout" do
      Tempfile.create(["deck", ".md"]) do |src|
        src.write("# Hi\n\nContent\n")
        src.flush
        out_path = "#{src.path}.json"
        code, out, _ = run(["--format", "json", "-o", out_path, src.path])
        expect(code).to eq(0)
        expect(out).to eq("") # nothing on stdout
        require "json"
        data = JSON.parse(File.read(out_path))
        expect(data["slides"][0]["title"]).to eq("Hi")
        File.delete(out_path)
      end
    end
  end

  describe "--watch option" do
    it "errors without an existing input file" do
      code, _, err = run(["--watch"], input: "# x")
      expect(code).to eq(1)
      expect(err).to include("--watch requires an existing input file")
    end
  end

  describe "frontmatter" do
    it "puts YAML frontmatter keys into metadata" do
      _, out, = run(["--format", "json"], input: "---\ntheme: dark\n---\n# Hello\n")
      require "json"
      data = JSON.parse(out)
      expect(data["metadata"]["theme"]).to eq("dark")
      expect(data["slides"][0]["title"]).to eq("Hello")
    end

    it "lets frontmatter title win and excludes the block from slides" do
      _, out, = run(["--format", "json"], input: "---\ntitle: From FM\n---\n# Body\n")
      data = JSON.parse(out)
      expect(data["metadata"]["title"]).to eq("From FM")
      expect(data["slides"].length).to eq(1)
      expect(data["slides"][0]["html"]).to include("<h1>Body</h1>")
    end

    it "keeps slides intact when there is no frontmatter" do
      _, out, = run(["--format", "json"], input: "# Slide 1\n\n---\n\n# Slide 2\n")
      data = JSON.parse(out)
      expect(data["slides"].length).to eq(2)
      expect(data["metadata"]).not_to have_key("theme")
    end
  end

  describe "title/lang priority between CLI options and frontmatter" do
    it "prefers --title over frontmatter title" do
      _, out, = run(["--format", "json", "--title", "From CLI"],
                    input: "---\ntitle: From FM\n---\n# Body\n")
      data = JSON.parse(out)
      expect(data["metadata"]["title"]).to eq("From CLI")
    end

    it "falls back to frontmatter title when --title is absent" do
      _, out, = run(["--format", "json"], input: "---\ntitle: From FM\n---\n# Body\n")
      data = JSON.parse(out)
      expect(data["metadata"]["title"]).to eq("From FM")
    end

    it "prefers --lang over frontmatter lang" do
      _, out, = run(["--format", "json", "--lang", "fr"],
                    input: "---\nlang: ja\n---\n# Body\n")
      data = JSON.parse(out)
      expect(data["metadata"]["language"]).to eq("fr")
    end

    it "falls back to frontmatter lang when --lang is absent" do
      _, out, = run(["--format", "json"], input: "---\nlang: ja\n---\n# Body\n")
      data = JSON.parse(out)
      expect(data["metadata"]["language"]).to eq("ja")
    end

    it "defaults lang to en when neither CLI nor frontmatter specify it" do
      _, out, = run(["--format", "json"], input: "# Body\n")
      data = JSON.parse(out)
      expect(data["metadata"]["language"]).to eq("en")
    end
  end
end
