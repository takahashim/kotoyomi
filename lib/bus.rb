module Kotoyomi
  # ウィンドウ間メッセージバス。BroadcastChannel("kotoyomi-sync")の薄いラッパ。
  # 同一ブラウザの別ウィンドウ(同一オリジン)同士でだけ届く。
  #
  # メッセージは { "kind" => ... } で種別を持つ:
  #   - { kind: "index",    index: n }          スライド送り(双方向)
  #   - { kind: "cmd",      cmd: "play"|... }    再生操作(発表者 → 投影)
  #   - { kind: "progress", value: 0.0..1.0 }    再生進捗(投影 → 発表者)
  #
  # BroadcastChannel は「自分が post したメッセージを自分には配送しない」。
  # 1 ウィンドウ = 1 VM = 1 チャンネルインスタンスなので、同一ウィンドウ内の
  # 複数コンポーネント(deck と slide 等)は互いの post を受け取らない(それで
  # よい。ウィンドウ内は signal で連携し、ウィンドウ間だけバスを使う)。
  #
  # 非対応環境(happy-dom 等)では channel が nil になり、全 API が no-op。
  module Bus
    CHANNEL = "kotoyomi-sync".freeze

    # 単一インスタンスを遅延生成。undefined(非対応)なら nil。
    def self.channel
      return @channel if @resolved

      @resolved = true
      ctor = JS.global[:BroadcastChannel]
      @channel = ctor.js_null? ? nil : ctor.new(CHANNEL)
    end

    def self.available?
      !channel.nil?
    end

    def self.post(hash)
      ch = channel
      ch.call(:postMessage, JS.object(hash)) if ch
    end
  end
end
