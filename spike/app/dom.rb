# Ported from lib/dom.rb for the mruby bridge.
#
# Differences vs ruby.wasm version:
#  - `require "js"` removed (mruby has no require; JS is aliased below)
#  - Element keeps registered callbacks alive in @callbacks so that
#    Value#on's returned wrapper isn't GC'd before the listener fires
#    (the C-side callback table pins the Proc, but the JS wrapper handle
#    needs a Ruby-side rooter).

JS = JSBridge

module Kotoyomi
  module DOM
    DOCUMENT = JS.global[:document]

    class Element
      def initialize(node)
        @node = node
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
        # `Element === child` instead of `child.is_a?(Element)`: child may
        # be a JS::Value (BasicObject), which has no Object methods.
        # Module#=== walks the class chain in C without dispatching on child.
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

      # Subscribe to a DOM event. Holds the returned wrapper Value in
      # @callbacks so it stays rooted for the lifetime of the Element
      # (Value#on returns the cb but our caller doesn't keep it).
      def on(event, options = nil, &block)
        @callbacks << @node.on(event.to_s, options, &block)
        self
      end
    end

    def self.[](id)
      node = DOCUMENT.getElementById(id)
      node.nil? ? nil : Element.new(node)
    end

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
      when :data  then elm.data = value
      else             elm[key] = value
      end
    end
  end
end
