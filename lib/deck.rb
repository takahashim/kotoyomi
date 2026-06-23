module Kotoyomi
  # テーマは Markdown の frontmatter(`theme:`)で指定し、slides.json の
  # metadata 経由で渡ってくる。画面での切り替え UI は廃止。<html data-theme="…">
  # を付け替えるだけで app.css の CSS 変数が一括で切り替わる。
  module Theme
    def self.apply(metadata)
      theme = metadata && metadata["theme"]
      return if theme.nil? || theme.to_s.empty?

      JS.global[:document][:documentElement].call(:setAttribute, "data-theme", theme.to_s)
    end
  end

  # 投影ビュー(SlideDeck)と発表者ビュー(PresenterDeck)で共有する、
  # スライド送り + ウィンドウ間同期 + キーボード操作。
  #
  # 同期は BroadcastChannel。同一ブラウザの別ウィンドウ(同一オリジン)同士で
  # @index をやり取りするので、サーバは不要。どちらのウィンドウで送っても
  # 双方が追従する。受信して適用するときは再送しない(broadcast: false)ので
  # ループしない。BroadcastChannel 非対応環境(happy-dom 等)では同期なしで
  # 通常動作する。
  module DeckControls
    # setup の最後に呼ぶ。@slides(signal)/ @index が定義済みであること。
    def install_controls
      @counter = computed { "#{@index.value + 1} / #{@slides.value.length}" }
      setup_sync
      setup_hot_reload
      document.on(:keydown) { |event| handle_key(event) }
    end

    def go_prev(_event = nil)
      go_to(@index.value - 1)
    end

    def go_next(_event = nil)
      go_to(@index.value + 1)
    end

    # index を変更し、他ウィンドウへ送る。remote 受信からの適用は broadcast: false。
    def go_to(i, broadcast: true)
      return if i < 0 || i >= @slides.value.length || i == @index.value

      @index.value = i
      Bus.post(kind: "index", index: i) if broadcast
    end

    private

    # 開発時のホットリロード。main.js が slides.json の変化を検知して
    # CustomEvent("kotoyomi:slides") を detail 付きで投げるので、それを取り込んで
    # @slides を差し替える(Lilac がその場で再描画)。本番(非 localhost)では
    # main.js がポーリングしないので、このリスナーは静かなまま。
    def setup_hot_reload
      document.on("kotoyomi:slides") { |event| reload_slides(event[:detail]) }
    end

    def reload_slides(detail)
      return if detail.nil? || detail.js_null?

      data = detail.to_ruby
      rows = Slides.parse(data)
      @slides.value = rows
      Theme.apply(data["metadata"])
      last = rows.length - 1
      @index.value = last if @index.value > last
      @index.value = 0 if @index.value < 0
    end

    def setup_sync
      return unless Bus.available?

      wrap(Bus.channel).on(:message) do |event|
        data = event[:data]
        next if data.js_null?

        case data[:kind].to_s
        when "index" then go_to(data[:index].to_i, broadcast: false)
        else handle_bus(data)
        end
      end
    end

    # 他種別メッセージの拡張点(既定は無視)。PresenterDeck が "progress" を扱う。
    def handle_bus(_data); end

    def handle_key(event)
      case event[:key].to_s
      when "ArrowRight"
        event.call(:preventDefault)
        go_next
      when "ArrowLeft"
        event.call(:preventDefault)
        go_prev
      when " ", "Spacebar"
        return if in_player?(event[:target])

        event.call(:preventDefault)
        go_next
      when "n", "N"
        event.call(:preventDefault)
        toggle_notes
      end
    end

    # event.target が audio 要素か .player 配下なら true(Space を奪わない)。
    def in_player?(target)
      !wrap(target).closest("audio, .player").nil?
    end

    def toggle_notes
      JS.global[:document][:documentElement][:classList].call(:toggle, "show-notes")
    end
  end

  # 投影(観客)ビュー。現在スライドだけを data-each で mount する。
  class SlideDeck < Lilac::Component
    include DeckControls

    def setup
      data = Fetchy.json("slides.json")
      # @slides は signal(ホットリロードで差し替えると Lilac が再描画する)。
      @slides = signal(Slides.parse(data))
      Theme.apply(data["metadata"])
      @index = signal(0)

      # 現在スライドのみを 1 要素配列で公開 → data-each が 1 枚だけ mount。
      @visible = computed do
        slide = @slides.value[@index.value]
        slide ? [slide] : []
      end

      # ナビボタンの disabled は HTML 側の data-attr-disabled が宣言的に反映する。
      @at_start = computed { @index.value <= 0 }
      @at_end   = computed { @index.value >= @slides.value.length - 1 }

      # 音声解錠。autoplay policy のため、このウィンドウが一度もユーザー操作
      # されないと(特に発表者ウィンドウからの)再生が弾かれる。デッキに音声が
      # あれば最初のページで解錠ボタンを出し、クリック(= user gesture)で解錠。
      @has_audio = computed { @slides.value.any? { |slide| !slide["vtt"].to_s.empty? } }
      @audio_locked = signal(true)
      @show_unlock = computed { @audio_locked.value && @has_audio.value && @index.value <= 0 }

      install_controls
    end

    # data-on-click="unlock_audio"。クリック自体が user gesture となり、以後
    # このウィンドウでの audio.play() が autoplay policy を通る。ボタンは消える。
    def unlock_audio(_event = nil)
      @audio_locked.value = false
    end
  end

  # 発表者ビュー。現在スライド + 続くページ(複数)+ 発表者ノートを表示し、
  # 投影ビューと @index を同期する。手元(ノート PC)用で、投影には出さない。
  class PresenterDeck < Lilac::Component
    include DeckControls

    # 先読みする「続くページ」の枚数。
    PREVIEW_COUNT = 3

    def setup
      data = Fetchy.json("slides.json")
      @slides = signal(Slides.parse(data))
      Theme.apply(data["metadata"])
      @index = signal(0)

      # 現在スライドを通常ビューと同じ配置(layout + 領域)で見せる。
      @current_layout = computed { current_slide["layout"] }
      @current_regions = computed { region_list(@index.value) }
      @notes = computed { notes_for(@index.value) }

      # 続くページ。各 region 連結ではなく html 全体(サムネ用)。
      @upcoming = computed do
        list = []
        (1..PREVIEW_COUNT).each do |offset|
          i = @index.value + offset
          slide = @slides.value[i]
          next unless slide

          list << { "n" => offset, "num" => (i + 1).to_s, "html" => slide_html(i) }
        end
        list
      end

      # プレイヤースライド(詩)のときだけ再生操作 + 進捗インジケータを出す。
      # 音は投影側で鳴り、ここはコマンドを送って進捗を受け取るリモコン。
      @has_player = computed do
        slide = @slides.value[@index.value]
        slide ? !slide["vtt"].to_s.empty? : false
      end
      @progress = signal(0.0) # 投影側から受け取る再生位置(0..1)
      @progress_pct = computed { "#{(@progress.value * 100).round(2)}%" }

      install_controls

      # インジケータの塗り幅を @progress に追従(Slide と同じ手法)。
      played = refs.progress_played
      effect { played.set_style("width", @progress_pct.value) }
      # スライドが変わったら進捗をリセット(新スライドの再生位置は未受信)。
      effect do
        @index.value
        @progress.value = 0.0
      end
    end

    # data-on-click。投影側へ再生コマンドを送る(ローカルでは音を鳴らさない)。
    def play(_event = nil)
      Bus.post(kind: "cmd", cmd: "play")
    end

    def pause(_event = nil)
      Bus.post(kind: "cmd", cmd: "pause")
    end

    def reset(_event = nil)
      Bus.post(kind: "cmd", cmd: "reset")
      @progress.value = 0.0
    end

    private

    # 投影側からの "progress" を受けてインジケータへ反映。
    def handle_bus(data)
      @progress.value = data[:value].to_f if data[:kind].to_s == "progress"
    end

    def current_slide
      @slides.value[@index.value] || {}
    end

    def slide_html(i)
      slide = @slides.value[i]
      slide ? slide["html"].to_s : ""
    end

    # スライドの "regions"(REGION_SEP 連結文字列)を data-each 用の領域配列へ。
    # Slide#@region_list と同じ展開を任意 index に対して行う。
    def region_list(i)
      slide = @slides.value[i]
      return [] unless slide

      slide["regions"].to_s.split(Slides::REGION_SEP, -1).each_with_index.map do |html, n|
        { "n" => n, "html" => html }
      end
    end

    def notes_for(i)
      slide = @slides.value[i]
      notes = slide && slide["notes"].to_s
      notes.to_s.empty? ? "(このスライドにノートはありません)" : notes
    end
  end

  # 印刷(PDF)ビュー。全スライドを data-each で一度に mount し、CSS の
  # @media print が 1 スライド = 1 ページに割り付ける。ナビ/同期/キー/解錠は無し。
  # プレイヤースライドは Slide が読み込み時に先頭の連を表示する(再生はしない)。
  class PrintDeck < Lilac::Component
    def setup
      data = Fetchy.json("slides.json")
      @slides = signal(Slides.parse(data))
      Theme.apply(data["metadata"])
      @visible = computed { @slides.value } # 全スライド
    end
  end

  Lilac.register "SlideDeck", SlideDeck
  Lilac.register "PresenterDeck", PresenterDeck
  Lilac.register "PrintDeck", PrintDeck
end
