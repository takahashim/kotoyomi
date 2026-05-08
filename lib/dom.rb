# mruby + mruby-js-bridge 前提。`require "js"` は不要 (gem として
# JS module が boot 時に自動定義される)。


module Kotoyomi
  # JS の document / Element を素直に扱うための薄いラッパー。
  # 完全には DOM を隠蔽せず、必要なら Element#native で JS::Value を取り出せる。
  module DOM
    DOCUMENT = JS.global[:document]

    # JS の DOM Element をラップして、よく使う操作を Ruby らしい API で提供する。
    # 任意のプロパティアクセスは [] / []= でフォールバック。
    class Element
      def initialize(node)
        @node = node
        # registered listeners のラッパー Value をここで保持。Element の
        # 寿命中は GC されないようにするため (callback の C-side proc は
        # JS 側で pin されるが、JS ラッパー関数の handle はここが
        # rooter になる)
        @callbacks = []
      end

      attr_reader :node
      alias native node

      def [](key) = @node[key]

      def []=(key, value)
        @node[key] = value
      end

      def id=(value)
        @node[:id] = value
      end

      def class_name=(value)
        @node[:className] = value
      end

      def text=(value)
        @node[:textContent] = value
      end

      def html=(value)
        @node[:innerHTML] = value
      end

      def data=(hash)
        hash.each { |k, v| @node[:dataset][k] = v.to_s }
      end

      def append(child)
        # `Element === child` は Ruby の Module#=== で C 実装。child が
        # JS::Object (BasicObject) の場合に is_a? を呼ばずに済む
        @node.appendChild((Element === child) ? child.native : child)
        self
      end

      def clear
        @node[:innerHTML] = ""
        self
      end

      def add_class(name)
        @node[:classList].add(name)
        self
      end

      def remove_class(name)
        @node[:classList].remove(name)
        self
      end

      def show
        @node[:hidden] = false
        self
      end

      def hide
        @node[:hidden] = true
        self
      end

      # イベント購読 (ブロックが JS コールバックとして渡る)
      # options に JS.object(once: true) などを渡せる
      def on(event, options = nil, &block)
        @callbacks << @node.on(event.to_s, options, &block)
        self
      end
    end

    # id で要素を取得して Element として返す。なければ nil
    def self.[](id)
      node = DOCUMENT.getElementById(id)
      node.nil? ? nil : Element.new(node)
    end

    # 新しい要素を作って Element として返す。
    #
    # 例:
    #   DOM.create(:div, id: "x", class: "stanza", data: { startTime: 0 }) do |div|
    #     div.append(DOM.create(:p, class: "stanza-line", text: "あさ"))
    #   end
    #
    # 特殊キー: :id, :class, :text, :html, :data
    # それ以外のキーは elm[key] = value にフォールバック。
    def self.create(tag, **attrs)
      elm = Element.new(DOCUMENT.createElement(tag.to_s))
      attrs.each { |key, value| apply_attr(elm, key, value) }
      yield elm if block_given?
      elm
    end

    # Internal helper. mruby は `private_class_method` を持たないので
    # 名前頭の `_` は付けず、命名規則だけで内部扱いとして扱う。
    def self.apply_attr(elm, key, value)
      case key
      when :id    then elm.id = value
      when :class then elm.class_name = value
      when :text  then elm.text = value
      when :html  then elm.html = value
      when :data  then elm.data = value
      else             elm[key] = value
      end
    end
  end
end
