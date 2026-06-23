require "tmpdir"
require "stringio"

RSpec.describe Kotoyomi::CLI::Generator do
  def gen(target)
    described_class.new(target, template_root: Kotoyomi::CLI::TEMPLATE_ROOT,
                                stdout: StringIO.new, stderr: StringIO.new)
  end

  it "scaffolds src/ (source) and public/ (runtime) separately" do
    Dir.mktmpdir do |dir|
      target = File.join(dir, "mydeck")
      expect(gen(target).generate).to eq(0)

      # 作者が書くもの
      expect(File.file?(File.join(target, "src", "deck.md"))).to be true
      expect(File.directory?(File.join(target, "src", "assets"))).to be true

      # 配信ランタイム一式
      %w[
        public/index.html public/app.css
        public/src/main.js public/lib/deck.rb
        public/vendor/lilac/lilac.wasm
        public/viewer/index.html public/viewer/presenter.html public/viewer/print.html
      ].each do |rel|
        expect(File.file?(File.join(target, rel))).to(be(true), "missing #{rel}")
      end

      # deck.md は frontmatter 付きの最小サンプル
      expect(File.read(File.join(target, "src", "deck.md"))).to include("theme: default")
    end
  end

  it "refuses to scaffold into a non-empty directory" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "existing"), "x")
      expect(gen(dir).generate).to eq(1)
    end
  end
end
