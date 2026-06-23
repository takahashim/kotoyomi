# frozen_string_literal: true

# Kotoyomi のビルド時 CLI(MRI)。Markdown デッキ → slides.json / standalone HTML。
# もとは別 gem rqslides。kotoyomi 専用なので Kotoyomi::CLI として取り込んだ。
# ランタイム(mruby/wasm の lib/*.rb)とは別プロセス・別名前空間。

require "red_quilt"
require "optparse"
require "fileutils"

require_relative "cli/version"
require_relative "cli/slide"
require_relative "cli/partitioner"
require_relative "cli/assets"
require_relative "cli/renderer/base"
require_relative "cli/renderer/html"
require_relative "cli/renderer/json"
require_relative "cli/generator"

module Kotoyomi
  class CLI
    USAGE = <<~USAGE
      Usage: kotoyomi [options] [file]

      Reads Markdown from FILE (or stdin if FILE is omitted) and writes slides
      to stdout (or to --output FILE).

      Options:
    USAGE

    DEFAULTS = {
      format: :html,
      auto_title: false,
      title: nil,
      # nil = unspecified. The "en" fallback is applied last in lang_for so we
      # can tell an explicit --lang apart (CLI takes precedence over frontmatter).
      lang: nil,
      output: nil,
      watch: false
    }.freeze

    # Default lang when neither the --lang option nor frontmatter provide one.
    DEFAULT_LANG = "en"

    FORMATS = %i[html json].freeze

    # --watch polling interval (seconds). A naive mtime watch that adds no gems.
    WATCH_INTERVAL = 0.3

    # プロジェクト操作のサブコマンド。これ以外で始まる引数は従来どおりの単発
    # 変換モード(Markdown → stdout / -o)として扱う(repo の make build / spec 用)。
    SUBCOMMANDS = %w[new build serve].freeze

    # 雛形(ランタイム一式)のコピー元。repo ルート / gem ルート(index.html /
    # app.css / src / lib / vendor/lilac / viewer/*.html がある場所)。
    TEMPLATE_ROOT = File.expand_path("../../..", __dir__)

    def self.run(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr)
      new(stdin: stdin, stdout: stdout, stderr: stderr).run(argv)
    end

    def initialize(stdin: $stdin, stdout: $stdout, stderr: $stderr)
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
    end

    def run(argv)
      if SUBCOMMANDS.include?(argv.first)
        send("cmd_#{argv.shift}", argv)
      else
        run_legacy(argv)
      end
    end

    private

    # ---- サブコマンド(プロジェクト操作)---------------------------------

    # kotoyomi new DIR — 雛形生成 + 初回ビルド。
    def cmd_new(argv)
      target = argv.first
      unless target
        stderr.puts "kotoyomi: usage: kotoyomi new DIR"
        return 1
      end

      code = Generator.new(target, template_root: TEMPLATE_ROOT,
                                   stdout: stdout, stderr: stderr).generate
      return code unless code.zero?

      build_project(File.expand_path(target))
      stdout.puts <<~MSG
        kotoyomi: #{target} を作成しました
          cd #{target}
          kotoyomi serve            # 配信 + src/deck.md 監視(編集で自動反映)→ http://127.0.0.1:8000/
      MSG
      0
    end

    # kotoyomi build [DIR] — deck/deck.md → public/viewer/slides.json(+ media 同期)。
    def cmd_build(argv)
      build_project(project_root(argv))
    end

    # kotoyomi serve [DIR] [--no-watch] — public/ を wsv で配信する。既定では
    # src/deck.md も監視し、変更時に再ビルド(ブラウザ側 hotreload.js が
    # slides.json の変化を拾ってその場で再描画)。--no-watch で監視を止め配信のみ。
    # wsv は子プロセス、監視ループは前面で回し Ctrl-C で両方停止。
    def cmd_serve(argv)
      watch = !argv.delete("--no-watch")
      root = project_root(argv)
      public_dir = File.join(root, "public")
      unless File.directory?(public_dir)
        stderr.puts "kotoyomi: #{public_dir} がありません(プロジェクト直下で実行)"
        return 1
      end

      deck = File.join(root, "src", "deck.md")
      watching = watch && File.file?(deck)
      build_project(root) if File.file?(deck) # 初回ビルド

      begin
        pid = spawn("wsv", public_dir)
      rescue Errno::ENOENT
        stderr.puts "kotoyomi: wsv が見つかりません(gem install wsv)"
        return 1
      end

      stdout.puts "kotoyomi: serving #{public_dir} at http://127.0.0.1:8000/ (Ctrl-C to stop)"
      stdout.puts "kotoyomi: watching #{deck}" if watching

      begin
        watching ? watch_loop(root) : Process.wait(pid)
      rescue Interrupt
        stdout.puts "\nkotoyomi: stopped"
      ensure
        terminate(pid)
      end
      0
    end

    # src/deck.md の mtime を監視し、変わるたびに再ビルド(Ctrl-C で抜ける)。
    def watch_loop(root)
      deck = File.join(root, "src", "deck.md")
      last = File.mtime(deck)
      loop do
        sleep(WATCH_INTERVAL)
        mtime = File.mtime(deck)
        next if mtime == last

        last = mtime
        build_project(root)
      end
    end

    def terminate(pid)
      Process.kill("TERM", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def project_root(argv)
      argv.first ? File.expand_path(argv.first) : Dir.pwd
    end

    # src/deck.md → public/viewer/slides.json を生成し、src/assets を viewer へ同期。
    def build_project(root)
      deck = File.join(root, "src", "deck.md")
      unless File.file?(deck)
        stderr.puts "kotoyomi: #{deck} が見つかりません(kotoyomi new で作成、またはプロジェクト直下で実行)"
        return 1
      end

      out = File.join(root, "public", "viewer", "slides.json")
      FileUtils.mkdir_p(File.dirname(out))
      File.write(out, build(File.read(deck), DEFAULTS.merge(format: :json)))
      sync_assets(root)
      stdout.puts "kotoyomi: built public/viewer/slides.json"
      0
    end

    # src/assets/* を public/viewer/assets/ にコピー(画像 / VTT の audio="assets/…" 解決用)。
    def sync_assets(root)
      src = File.join(root, "src", "assets")
      return unless File.directory?(src)

      dst = File.join(root, "public", "viewer", "assets")
      FileUtils.mkdir_p(dst)
      Dir.children(src).each do |entry|
        next if entry == ".gitkeep"

        FileUtils.cp_r(File.join(src, entry), dst)
      end
    end

    # ---- 単発変換モード(従来) ------------------------------------------

    def run_legacy(argv)
      options = parse_options(argv)
      return options if options.is_a?(Integer)

      return run_watch(argv, options) if options[:watch]

      source = read_source(argv)
      return 1 unless source

      write_output(build(source, options), options[:output])
      0
    end

    attr_reader :stdin, :stdout, :stderr

    def parse_options(argv)
      options = DEFAULTS.dup
      parser = OptionParser.new do |opts|
        opts.banner = USAGE
        opts.on("--format FORMAT", FORMATS, "Output format: html (default), json") do |f|
          options[:format] = f
        end
        opts.on("--auto-title",
                "Use the first heading's text as title") do
          options[:auto_title] = true
        end
        opts.on("--title TITLE", "Explicit title text") do |t|
          options[:title] = t
        end
        opts.on("--lang LANG", "html lang attribute (default: \"en\")") do |l|
          options[:lang] = l
        end
        opts.on("-o", "--output FILE", "Write to FILE instead of stdout") do |path|
          options[:output] = path
        end
        opts.on("-w", "--watch", "Rebuild on input-file change (requires FILE)") do
          options[:watch] = true
        end
        opts.on("-h", "--help", "Show this help") do
          stderr.puts opts
          return 0
        end
        opts.on("-v", "--version", "Show version") do
          stderr.puts "kotoyomi #{Kotoyomi::CLI::VERSION}"
          return 0
        end
      end

      begin
        parser.parse!(argv)
      rescue OptionParser::ParseError => e
        stderr.puts "kotoyomi: #{e.message}"
        stderr.puts parser
        return 1
      end

      options
    end

    def read_source(argv)
      if argv.empty?
        stdin.read
      elsif argv.size == 1
        path = argv.first
        unless File.file?(path)
          stderr.puts "kotoyomi: no such file: #{path}"
          return nil
        end
        File.read(path)
      else
        stderr.puts "kotoyomi: too many arguments: #{argv.inspect}"
        nil
      end
    end

    # Render the document to the final output string. JSON gets a trailing
    # newline so stdout/file output matches the historical `puts` behaviour.
    # Frontmatter is parsed by red_quilt (`frontmatter: true`): it is stripped
    # from the body and exposed via `doc.frontmatter` (Hash | nil).
    def build(source, options)
      doc = RedQuilt.parse(source, frontmatter: true)
      case options[:format]
      when :html then render_html(doc, options)
      when :json then "#{render_json(doc, options)}\n"
      end
    end

    def write_output(output, path)
      if path
        File.write(path, output)
      else
        stdout.write(output)
      end
    end

    # Poll the input file's mtime and rebuild on change. Pure-Ruby (no extra
    # gem). Stops on Ctrl-C. Build errors are reported but don't stop watching.
    def run_watch(argv, options)
      if argv.size != 1 || !File.file?(argv.first)
        stderr.puts "kotoyomi: --watch requires an existing input file"
        return 1
      end

      path = argv.first
      target = options[:output] || "(stdout)"
      stderr.puts "kotoyomi: watching #{path} -> #{target} (Ctrl-C to stop)"

      last = nil
      loop do
        mtime = File.mtime(path)
        if mtime != last
          last = mtime
          rebuild(path, options)
        end
        sleep(WATCH_INTERVAL)
      end
    rescue Interrupt
      stderr.puts "\nkotoyomi: stopped"
      0
    end

    def rebuild(path, options)
      write_output(build(File.read(path), options), options[:output])
      stderr.puts "kotoyomi: built #{options[:output] || '(stdout)'} #{Time.now.strftime('%H:%M:%S')}"
    rescue StandardError => e
      stderr.puts "kotoyomi: build error: #{e.message}"
    end

    def render_html(doc, options)
      doc.to_slides(title: title_for(doc, options), lang: lang_for(doc, options))
    end

    def render_json(doc, options)
      doc.to_slides_json(title: title_for(doc, options), lang: lang_for(doc, options))
    end

    # title / lang prefer the CLI option, then frontmatter, then a default.
    # For title, --auto-title additionally supplies the first heading as the
    # default when nothing else is set.
    def title_for(doc, options)
      front = doc.frontmatter || {}
      title = options[:title] || front["title"]
      title = doc.first_heading_text.to_s if title.nil? && options[:auto_title]
      title.to_s
    end

    def lang_for(doc, options)
      front = doc.frontmatter || {}
      (options[:lang] || front["lang"] || front["language"] || DEFAULT_LANG).to_s
    end

    # Slide-rendering entry points mixed into RedQuilt::Document, so callers can
    # write `doc.to_slides_json`. Kept as an explicit module for discoverability.
    module DocumentSlides
      def to_slides(title: nil, lang: "en")
        Kotoyomi::CLI::Renderer::HTML.new(self, title: title.to_s, lang: lang.to_s).render
      end

      def to_slides_json(title: nil, lang: "en")
        Kotoyomi::CLI::Renderer::JSON.new(self, title: title.to_s, lang: lang.to_s).render
      end
    end
  end
end

RedQuilt::Document.include(Kotoyomi::CLI::DocumentSlides)
