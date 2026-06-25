# frozen_string_literal: true

# Kotoyomi のビルド時 CLI(MRI)。Markdown デッキ → slides.json / standalone HTML。
# もとは別 gem rqslides。kotoyomi 専用なので Kotoyomi::CLI として取り込んだ。
# ランタイム(mruby/wasm の lib/*.rb)とは別プロセス・別名前空間。

require "red_quilt"
require "optparse"

require_relative "cli/version"
require_relative "cli/slide"
require_relative "cli/partitioner"
require_relative "cli/assets"
require_relative "cli/renderer/base"
require_relative "cli/renderer/html"
require_relative "cli/renderer/json"
require_relative "cli/converter"
require_relative "cli/generator"
require_relative "cli/reload_server"
require_relative "cli/project"
require_relative "cli/file_watcher"
require_relative "cli/project_builder"
require_relative "cli/serve_command"

module Kotoyomi
  class CLI
    # `kotoyomi --help` の出力。プロジェクト操作のサブコマンドが公開インタフェース。
    # 単発変換モード(run_legacy)は社内ツール/Makefile 用の低レベル退避路として
    # 残してあるが、ここには載せない(USAGE バナーがパースエラー時にだけ見せる)。
    HELP = <<~HELP
      Usage: kotoyomi <command> [DIR] [options]

      Commands:
        new DIR        Scaffold a project (src/ + public/) and run the first build
        build [DIR]    Build src/deck.md -> public/viewer/slides.json (syncs assets)
        serve [DIR]    Serve public/ and watch src/deck.md, rebuilding on change
                       (--no-watch to disable); http://127.0.0.1:8000/
        upgrade [DIR]  Refresh public/'s bundled runtime to the current kotoyomi
                       (keeps src/ and built output)

      [DIR] defaults to the current directory.

        -h, --help     Show this help
        -v, --version  Show version
    HELP

    # OptionParser のバナー。単発変換モードのパースエラー時にだけ表示する
    # (--help はサブコマンド中心の HELP を出すので、ここには現れない)。
    USAGE = "Usage: kotoyomi [options] [FILE]\n"

    DEFAULTS = {
      format: :html,
      auto_title: false,
      title: nil,
      # nil = unspecified. The "en" fallback is applied last in Converter so we
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

    # プロジェクト操作のサブコマンド→メソッド名マップ。これ以外で始まる引数は
    # 従来どおりの単発変換モード(Markdown → stdout / -o)として扱う。
    SUBCOMMAND_MAP = {
      "new" => :cmd_new,
      "build" => :cmd_build,
      "serve" => :cmd_serve,
      "upgrade" => :cmd_upgrade
    }.freeze

    # parse_options での早期終了(help / version / parse error)のシグナル。
    # 制御フロー用なので Exception 継承(SystemExit と同じ理屈)─ 経路上の汎用
    # rescue StandardError(例: rebuild)に飲まれず、捕捉は rescue Abort で名指す。
    Abort = Class.new(Exception) do
      attr_reader :code

      def initialize(code)
        @code = code
        super(code.to_s)
      end
    end

    # 雛形(ランタイム一式)のコピー元。repo ルート / gem ルート(index.html /
    # app.css / src / lib / vendor/lilac / viewer/*.html がある場所)。
    TEMPLATE_ROOT = File.expand_path("../../..", __dir__)

    # serve のポート。wsv が SERVE_PORT、ライブリロード SSE が +1(8001)。
    SERVE_PORT = 8000

    def self.run(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr)
      new(stdin: stdin, stdout: stdout, stderr: stderr).run(argv)
    end

    def initialize(stdin: $stdin, stdout: $stdout, stderr: $stderr)
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
    end

    def run(argv)
      if (method = SUBCOMMAND_MAP[argv.first])
        send(method, argv.drop(1))
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

      code = generator(target).generate
      return code unless code.zero?

      project = Project.new(target)
      builder(project).build
      stdout.puts <<~MSG
        kotoyomi: #{target} を作成しました
          cd #{target}
          kotoyomi serve            # 配信 + src/deck.md 監視(編集で自動反映)→ http://127.0.0.1:8000/
      MSG
      0
    end

    # kotoyomi build [DIR] — src/deck.md → public/viewer/slides.json(+ assets 同期)。
    def cmd_build(argv)
      builder(project_from(argv)).build
    end

    # kotoyomi upgrade [DIR] — public/ のランタイム同梱物を最新の kotoyomi で更新。
    # src/ と build 生成物は保持。kotoyomi 自体を更新したあとに実行する。
    def cmd_upgrade(argv)
      project = project_from(argv)
      code = generator(project.root).upgrade
      stdout.puts "kotoyomi: #{project.public_dir} のランタイムを更新しました" if code.zero?
      code
    end

    # kotoyomi serve [DIR] [--no-watch] — public/ を wsv で配信(既定で src/deck.md
    # を監視し変更時に再ビルド)。運用は ServeCommand に委譲する。
    def cmd_serve(argv)
      watch = !argv.delete("--no-watch")
      project = project_from(argv)
      ServeCommand.new(project, builder(project), watch: watch,
                                                  stdout: stdout, stderr: stderr).run
    end

    # 引数 DIR(なければカレント)から Project を組み立てる。
    def project_from(argv)
      Project.new(argv.first || Dir.pwd)
    end

    def generator(target)
      Generator.new(target, template_root: TEMPLATE_ROOT, stdout: stdout, stderr: stderr)
    end

    # プロジェクトビルドは常に JSON 出力。変換は Converter に丸ごと委譲する。
    def builder(project)
      ProjectBuilder.new(project, renderer: Converter.new(format: :json),
                                  stdout: stdout, stderr: stderr)
    end

    # ---- 単発変換モード(従来) ------------------------------------------

    def run_legacy(argv)
      options = parse_options(argv)
      return run_watch(argv, options) if options[:watch]

      source = read_source(argv)
      return 1 unless source

      write_output(converter(options).call(source), options[:output])
      0
    rescue Abort => e
      e.code
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
          stderr.puts HELP
          raise Abort.new(0)
        end
        opts.on("-v", "--version", "Show version") do
          stderr.puts "kotoyomi #{Kotoyomi::CLI::VERSION}"
          raise Abort.new(0)
        end
      end

      parser.parse!(argv)
      options
    rescue OptionParser::ParseError => e
      stderr.puts "kotoyomi: #{e.message}"
      stderr.puts parser
      raise Abort.new(1)
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

    # オプションから Converter を組み立てる(変換規則は Converter 側に集約)。
    def converter(options)
      Converter.new(format: options[:format], title: options[:title],
                    auto_title: options[:auto_title], lang: options[:lang])
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
    # 別プロセスで配信(make serve = wsv)していてもブラウザへ reload を push
    # できるよう、SSE サーバ(:SERVE_PORT+1)も立てて再ビルド時に通知する。
    def run_watch(argv, options)
      if argv.size != 1 || !File.file?(argv.first)
        stderr.puts "kotoyomi: --watch requires an existing input file"
        return 1
      end

      path = argv.first
      target = options[:output] || "(stdout)"
      stderr.puts "kotoyomi: watching #{path} -> #{target} (Ctrl-C to stop)"

      reload = ReloadServer.new(SERVE_PORT + 1).start
      rebuild(path, options) # 初回ビルド(以降は変更時のみ)
      begin
        FileWatcher.new(path, interval: WATCH_INTERVAL).each_change do
          rebuild(path, options)
          reload&.notify
        end
      rescue Interrupt
        stderr.puts "\nkotoyomi: stopped"
      ensure
        reload&.stop
      end
      0
    end

    def rebuild(path, options)
      write_output(converter(options).call(File.read(path)), options[:output])
      stderr.puts "kotoyomi: built #{options[:output] || '(stdout)'} #{Time.now.strftime('%H:%M:%S')}"
    rescue StandardError => e
      stderr.puts "kotoyomi: build error: #{e.message}"
    end
  end
end
