require "js"

module Kotoyomi
  # TS から呼ぶための薄い委譲。ロジック本体は App#start に置く。
  def self.start
    App.new.start
  end

  class App
    def initialize
      document = JS.global[:document]
      @audio = document.getElementById("audio")
      @track_el = document.getElementById("track")
      @poem = document.getElementById("poem")
      @error_el = document.getElementById("error")
      @reset_btn = document.getElementById("reset")
    end

    def start
      wait_for_track_load
      track = @track_el[:track]
      track[:mode] = "hidden"
      cues = track[:cues]

      elements = Renderer.new(cues, @poem).render
      Player.new(track, elements)

      @reset_btn.addEventListener("click") { @audio[:currentTime] = 0 }
      @audio[:currentTime] = 0
    rescue => e
      report_error(e)
      raise
    end

    private

    def wait_for_track_load
      ready = @track_el[:readyState].to_i
      return if ready == 2
      raise "track load error" if ready == 3

      JS.eval(<<~JS).await
        return new Promise((resolve, reject) => {
          const el = document.getElementById("track");
          el.addEventListener("load", () => resolve(), { once: true });
          el.addEventListener("error", () => reject(new Error("track load error")), { once: true });
        });
      JS
    end

    def report_error(e)
      JS.global[:console].error(e.message)
      @error_el[:textContent] = "起動に失敗しました。\n#{e.message}"
      @error_el[:hidden] = false
    end
  end
end
