require "js"

module Kotoyomi
  # アプリ層で発生する想定済みエラーの基底クラス。
  class Error < StandardError; end

  # 字幕トラック (`<track>`) のロード失敗。
  class TrackLoadError < Error; end

  # TS から呼ぶための薄い委譲。ロジック本体は App#start に置く。
  def self.start
    App.new.start
  end

  class App
    def initialize
      @audio     = DOM["audio"]
      @track_el  = DOM["track"]
      @poem      = DOM["poem"]
      @error_el  = DOM["error"]
      @reset_btn = DOM["reset"]
    end

    def start
      wait_for_track_load
      track = @track_el[:track]
      track[:mode] = "hidden"
      cues = track[:cues]

      elements = Renderer.new(cues, @poem).render
      Player.new(track, elements, @audio).start

      @reset_btn.on(:click) { reset_audio }
      reset_audio
    rescue Error => e
      report_error(e)
      raise
    end

    private

    def reset_audio
      @audio[:currentTime] = 0
    end

    def wait_for_track_load
      ready = @track_el[:readyState].to_i
      return if ready == 2
      raise TrackLoadError, "track load error" if ready == 3

      JS.eval(<<~JS).await
        return new Promise((resolve, reject) => {
          const el = document.getElementById("track");
          el.addEventListener("load", () => resolve(), { once: true });
          el.addEventListener("error", () => reject(new Error("track load error")), { once: true });
        });
      JS
    rescue JS::Error => e
      raise TrackLoadError, e.message
    end

    def report_error(err)
      JS.global[:console].error(err.message)
      @error_el.text = "起動に失敗しました。\n#{err.message}"
      @error_el.show
    end
  end
end
