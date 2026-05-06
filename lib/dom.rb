require "js"

module Kotoyomi
  # JS の document / Element を素直に扱うための薄いラッパー。
  # 完全には DOM を隠蔽せず、必要なら Element#native で JS::Object を取り出せる。
  module DOM
    DOCUMENT = JS.global[:document]

    # id で要素を取得して Element として返す。
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

    def self.apply_attr(elm, key, value)
      case key
      when :id    then elm.id = value
      when :class then elm.class_name = value
      when :text  then elm.text = value
      when :html  then elm.html = value
      when :data  then value.each { |k, v| elm.dataset(k, v) }
      else             elm[key] = value
      end
    end
    private_class_method :apply_attr
  end

  # JS の DOM Element をラップして、よく使う操作を Ruby らしい API で提供する。
  # 任意のプロパティアクセスは [] / []= でフォールバック。
  class Element
    def initialize(node)
      @node = node
    end

    # 元の JS::Object を取り出す (JS API に直接渡すとき用)。
    attr_reader :node
    alias native node

    # 任意プロパティアクセス
    def [](key) = @node[key]

    def []=(key, value)
      @node[key] = value
    end

    # よく使う属性
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

    def dataset(key, value)
      @node[:dataset][key] = value.to_s
      self
    end

    # 子要素操作
    def append(child)
      @node.appendChild(child.is_a?(Element) ? child.native : child)
      self
    end

    def clear
      @node[:innerHTML] = ""
      self
    end

    # CSS クラス
    def add_class(name)
      @node[:classList].add(name)
      self
    end

    def remove_class(name)
      @node[:classList].remove(name)
      self
    end

    # 表示制御
    def show
      @node[:hidden] = false
      self
    end

    def hide
      @node[:hidden] = true
      self
    end

    # イベント購読 (ブロックが JS コールバックとして渡る)
    def on(event, &)
      @node.addEventListener(event.to_s, &)
      self
    end
  end
end
