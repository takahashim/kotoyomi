module Kotoyomi
  # アプリ層で発生する想定済みエラーの基底クラス。
  class Error < StandardError; end

  # 字幕トラック (`<track>`) のロード失敗。
  class TrackLoadError < Error; end

  # 1枚のスライドを表す Lilac::Component。SlideDeck の data-each 行として
  # mount され、props は item(slides.json の1行)から auto-fill される。
  #
  # - 本文(markdown HTML)は data-unsafe-html で表示(信頼できるビルド出力)。
  # - @vtt があるスライド = プレイヤースライド。VTT を Blob URL 化して
  #   <track> に流し、kotoyomi 由来の cue→stanza 表示 + 音声同期を行う。
  #
  # スライド離脱時は data-each の keyed reconciler が unmount を呼び、
  # cleanup(audio.pause / Blob revoke)・listener・effect が自動解放される。
  class Slide < Lilac::Component
    prop :index,   Integer
    prop :html,    String, default: ""
    prop :layout,  String, default: nil
    prop :regions, String, default: ""
    prop :notes,   String, default: nil
    prop :audio,   String, default: nil
    prop :vtt,     String, default: nil

    def setup
      @stanzas = signal([])
      @current = -1
      # 再生進捗 (0.0..1.0)。再生済み/未再生を 2 色で塗り分ける自前バーを
      # data-style で駆動する(ネイティブの細い再生ヘッドより視認性が高い)。
      # 非プレイヤースライドでも data-style バインドが解決できるよう先に定義する。
      @progress = signal(0.0)
      @progress_pct = computed { "#{(@progress.value * 100).round(2)}%" }
      @has_player = computed { !@vtt.value.to_s.empty? }

      # 本文の領域(region)。Slides が REGION_SEP で連結した 1 文字列を領域
      # 配列へ戻す(分割レイアウトは複数、通常は 1)。data-each 用に String
      # キーの行 hash にする。-1 で末尾の空領域も保持。
      @region_list = computed do
        @regions.value.to_s.split(Slides::REGION_SEP, -1).each_with_index.map do |html, n|
          { "n" => n, "html" => html }
        end
      end
      # 発表者ノート。本文があるときだけ枠を出す(表示切替は deck の n キーが
      # <html> の show-notes クラスで行う)。
      @has_notes = computed { !@notes.value.to_s.empty? }

      # 非プレイヤースライド: 本文(region)を出すだけ。
      return unless @has_player.value

      # 進捗バーの塗り幅を @progress に追従させる。Lilac は data-style を
      # 提供しないので、canonical な RefElement#set_style を effect で駆動する。
      played = refs.progress_played
      effect { played.set_style("width", @progress_pct.value) }

      # 発表者ウィンドウからの再生コマンドでこのスライドの audio を操作する
      # (音は投影側=ここで鳴る)。listener は unmount で自動解放。
      if Bus.available?
        wrap(Bus.channel).on(:message) do |event|
          data = event[:data]
          next if data.js_null? || data[:kind].to_s != "cmd"

          case data[:cmd].to_s
          when "play"  then safe_play
          when "pause" then refs.audio.pause
          when "reset" then reset_audio
          end
        end
      end

      # 離脱時に確実に音を止め、Blob URL を解放する。
      cleanup { refs.audio.pause }
      url = VttTrack.attach(refs.track, refs.audio, @vtt.value, @audio.value)
      cleanup { VttTrack.revoke(url) }

      # data-each 行(Slide)は MutationObserver 経由で mount されるため
      # setup は eval fiber の外で走り、`await` は使えない。よってトラックの
      # ロードはイベント駆動で待つ(cuechange と同じ流儀)。
      case refs.track.to_js[:readyState].to_i
      when 2 # LOADED
        build_player
      when 3 # ERROR
        report_error(TrackLoadError.new("track load error"))
      else
        refs.track.on(:load) { build_player }
        refs.track.on(:error) { report_error(TrackLoadError.new("track load error")) }
      end
    end

    # `data-on-click="play"` から呼ばれる(ボタンクリック = user gesture なので
    # play() は autoplay policy に弾かれない)。
    def play(_event = nil)
      safe_play
    end

    # `data-on-click="pause"` から呼ばれる。
    def pause(_event = nil)
      refs.audio.pause
    end

    # `data-on-click="reset"` から呼ばれる。
    def reset(_event = nil)
      reset_audio
    end

    private

    # audio.play() は Promise を返す。autoplay policy で reject されると
    # 「Uncaught (in promise) NotAllowedError」になるので必ず catch して握り
    # つぶす。投影ウィンドウの音声解錠は SlideDeck の最初のページのボタンが担う。
    def safe_play
      promise = refs.audio.to_js.call(:play)
      return if promise.nil? || promise.js_null?

      promise.call(:catch, JS.callback { |_err| })
    end

    # 自前プログレスバーのクリック位置にシークする(ネイティブ controls を
    # 隠す代わりの seek 手段)。
    def seek(event)
      audio = refs.audio
      duration = audio[:duration].to_f
      return if duration <= 0

      rect = refs.progress.getBoundingClientRect
      width = rect[:width].to_f
      return if width <= 0

      frac = (event[:clientX].to_f - rect[:left].to_f) / width
      frac = 0.0 if frac < 0.0
      frac = 1.0 if frac > 1.0
      audio[:currentTime] = frac * duration
    end

    # トラックのロード完了後に呼ばれ、cue→stanza を構築して同期を始める。
    def build_player
      track = refs.track[:track]
      track[:mode] = "hidden"
      cues = track[:cues]

      @stanzas.value = Renderer.new(cues).to_stanzas.map do |stanza|
        stanza.merge("active" => signal(false))
      end

      @player = Player.new(cues, refs.audio)
      refs.track.on(:cuechange) { highlight }
      refs.audio.on(:timeupdate) { update_progress }
      refs.progress.on(:click) { |event| seek(event) }
      highlight
      reset_audio
    rescue StandardError => e
      report_error(e)
    end

    # audio.currentTime / duration を 0..1 の進捗 signal に反映する。
    def update_progress
      audio = refs.audio
      duration = audio[:duration].to_f
      @progress.value = duration > 0 ? (audio[:currentTime].to_f / duration) : 0.0
      broadcast_progress
    end

    # 発表者ウィンドウのインジケータ用に再生位置(0..1)を送る。
    def broadcast_progress
      Bus.post(kind: "progress", value: @progress.value) if Bus.available?
    end

    # active な連を index へ移す。前後の連の Signal を flip するだけ。
    def highlight
      index = @player.active_cue_index
      return if index == @current

      list = @stanzas.value
      list[@current]["active"].value = false if @current >= 0 && list[@current]
      @current = index
      list[index]["active"].value = true if index >= 0 && list[index]
    end

    def reset_audio
      refs.audio[:currentTime] = 0
      @progress.value = 0.0
      broadcast_progress
    end

    def report_error(err)
      Lilac.logger.error("slide", err)
      refs.error.text = "再生に失敗しました。\n#{err.message}"
      refs.error.hidden = false
    end
  end

  Lilac.register "Slide", Slide
end
