# Ported from lib/kotoyomi.rb. Major change:
#  - wait_for_track_load is now callback-based. mruby has no fiber/Asyncify
#    so we can't `JS.eval(...).await`. Instead we register one-shot load /
#    error listeners and `proceed` is called on success.
#  - App#start splits into start (sync setup + register listeners) and
#    on_track_loaded (the post-load body that builds Renderer + Player).

module Kotoyomi
  class Error < StandardError; end
  class TrackLoadError < Error; end

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
      wait_for_track_load { on_track_loaded }
    rescue Error => err
      report_error(err)
      raise
    end

    private

    def on_track_loaded
      track = @track_el[:track]
      track[:mode] = "hidden"
      cues = track[:cues]

      elements = Renderer.new(cues, @poem).render
      Player.new(track, elements, @audio).start

      @reset_btn.on(:click) { reset_audio }
      reset_audio
    rescue Error => err
      report_error(err)
    end

    def reset_audio
      @audio[:currentTime] = 0
    end

    # Wait for the <track> to finish loading, then call `proceed`.
    # Replaces the ruby.wasm `JS.eval(...).await` pattern — instead of
    # blocking the fiber, we register one-shot load/error listeners and
    # proceed asynchronously when the load event fires.
    def wait_for_track_load(&proceed)
      ready = @track_el[:readyState].to_i
      return proceed.call if ready == 2
      raise TrackLoadError, "track load error" if ready == 3

      once = JS.object(once: true)
      @track_el.on(:load, once) { proceed.call }
      @track_el.on(:error, once) { report_error(TrackLoadError.new("track load error")) }
    end

    def report_error(err)
      JS.global[:console].error(err.message)
      @error_el.text = "起動に失敗しました。\n#{err.message}"
      @error_el.show
    end
  end
end
