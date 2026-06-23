# frozen_string_literal: true

class Kotoyomi::CLI
  # `kotoyomi serve` の運用主体。public/ を wsv(子プロセス)で配信し、watch 時は
  # src/deck.md を監視して再ビルド + SSE 通知する。子プロセスと SSE サーバの
  # ライフサイクル(起動・待機・Ctrl-C での確実な停止)を一手に引き受ける。
  class ServeCommand
    def initialize(project, builder, watch:, stdout:, stderr:)
      @project = project
      @builder = builder
      @watch = watch
      @stdout = stdout
      @stderr = stderr
    end

    def run
      unless @project.public?
        @stderr.puts "kotoyomi: #{@project.public_dir} がありません(プロジェクト直下で実行)"
        return 1
      end

      watching = @watch && @project.deck?
      @builder.build if @project.deck? # 初回ビルド

      pid = spawn_server
      return 1 unless pid

      reload = watching ? ReloadServer.new(SERVE_PORT + 1).start : nil
      announce(watching)

      begin
        watching ? watch_loop(reload) : Process.wait(pid)
      rescue Interrupt
        @stdout.puts "\nkotoyomi: stopped"
      ensure
        reload&.stop
        terminate(pid)
      end
      0
    end

    private

    def spawn_server
      spawn("wsv", "-p", SERVE_PORT.to_s, @project.public_dir)
    rescue Errno::ENOENT
      @stderr.puts "kotoyomi: wsv が見つかりません(gem install wsv)"
      nil
    end

    # 変更時に再ビルド → SSE 通知。ブラウザ側 hotreload.js が slides.json の変化を
    # 拾ってその場で再描画する。
    def watch_loop(reload)
      FileWatcher.new(@project.deck_path, interval: WATCH_INTERVAL).each_change do
        @builder.build
        reload&.notify
      end
    end

    def announce(watching)
      @stdout.puts "kotoyomi: serving #{@project.public_dir} at http://127.0.0.1:#{SERVE_PORT}/ (Ctrl-C to stop)"
      @stdout.puts "kotoyomi: watching #{@project.deck_path}(保存すると自動リロード)" if watching
      @stdout.flush
    end

    def terminate(pid)
      Process.kill("TERM", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end
end
