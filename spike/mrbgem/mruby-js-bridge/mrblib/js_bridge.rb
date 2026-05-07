# JSBridge — high-level Ruby API around the C primitives in js_bridge.c.
#
# JSBridge::Value is defined in C as a BasicObject subclass with
# MRB_TT_DATA. Each instance carries a JS handle which is auto-released
# when the Ruby object is GC'd. Inheriting from BasicObject (like
# ruby.wasm's JS::Object) keeps Object methods like `then`, `tap`,
# `itself`, `inspect`, `==` from shadowing JS dispatch via method_missing.
#
# Example:
#   doc = JSBridge.global[:document]
#   doc[:title] = "hello"
#   doc.call(:getElementById, "audio")

module JSBridge
  class << self
    def global
      Value.new(_global)
    end

    def eval(src)
      Value.new(_eval(src))
    end

    # Wrap a Ruby block as a JS callback function.
    # Returns a Value holding the JS wrapper. Note: the Proc is held
    # alive in the C-side callback table for the lifetime of the VM.
    def callback(&block)
      raise ArgumentError, "block required" unless block
      Value.new(_make_callback(block))
    end

    # Convert a Ruby value into a Value (handle).
    # Already-Value passes through; primitives get a fresh handle that the
    # GC will release once the temporary Value is unreachable.
    #
    # Defined as a module function (not on Value) so constant lookup for
    # Integer/String/ArgumentError works — Value < BasicObject can't see
    # those constants without `::` prefixing.
    #
    # Symbol/Array/Hash are wrapped recursively so callers can write
    # `obj[:opts] = { once: true, capture: false }` naturally.
    def wrap(v)
      case v
      when Value then v
      when Integer then Value.new(_from_int(v))
      when Float then Value.new(_from_float(v))
      when String then Value.new(_from_string(v))
      when Symbol then Value.new(_from_string(v.to_s))
      when nil then Value.new(_eval("null"))
      when true then Value.new(_eval("true"))
      when false then Value.new(_eval("false"))
      when Array then array(v)
      when Hash then object(v)
      else
        raise ArgumentError, "cannot wrap #{v.class} as JS value"
      end
    end

    # Build a JS object literal from a Ruby Hash. Recursively wraps values.
    #   JSBridge.object(once: true)  →  { once: true }
    def object(hash = {})
      obj = eval("({})")
      hash.each { |k, v| obj[k.to_s] = v }
      obj
    end

    # Build a JS array from a Ruby Array. Recursively wraps elements.
    #   JSBridge.array([1, "two", true])  →  [1, "two", true]
    def array(items = [])
      arr = eval("[]")
      items.each { |item| arr.push(item) }
      arr
    end
  end

  class Value
    # `initialize(handle)` and `handle` are defined in C.
    # Inherits from BasicObject — only define what we actually need.

    def [](key)
      Value.new(JSBridge._get(handle, key.to_s))
    end

    def []=(key, value)
      # Keep `v` in a local so the temp handle isn't released by GC
      # before _set crosses the WASM boundary.
      v = JSBridge.wrap(value)
      JSBridge._set(handle, key.to_s, v.handle)
      value
    end

    # Call a JS method. If a block is given, it's wrapped as a JS callback
    # and appended as the last argument (ruby.wasm convention).
    def call(method, *args, &block)
      args = args + [JSBridge.callback(&block)] if block
      # IMPORTANT: hold the wrapped Values in `wrapped` until _call
      # returns. Otherwise mruby's GC may collect them between
      # `.handle` extraction and the WASM call, releasing the JS handles
      # we just built.
      wrapped = args.map { |a| JSBridge.wrap(a) }
      arg_handles = wrapped.map(&:handle)
      result = Value.new(JSBridge._call(handle, method.to_s, arg_handles))
      # `wrapped` is now garbage; temp handles get released next GC.
      wrapped = nil
      result
    end

    # Call as a JS constructor: `Foo.new(args)` → `new Foo(args)`.
    # Same arg-rooting pattern as #call to keep wrapped Values alive
    # across the WASM boundary.
    def new(*args)
      wrapped = args.map { |a| JSBridge.wrap(a) }
      arg_handles = wrapped.map(&:handle)
      result = Value.new(JSBridge._new(handle, arg_handles))
      wrapped = nil
      result
    end

    # Call a JS method with arguments from an Array. Mirrors ruby.wasm's
    # JS::Object#apply (and JS's Function.prototype.apply semantics — the
    # array is spread as positional args, not passed as a single arg).
    def apply(method, args_array, &block)
      call(method, *args_array, &block)
    end

    def to_s
      JSBridge._to_string(handle)
    end

    def to_i
      JSBridge._to_int(handle)
    end

    def to_f
      JSBridge._to_float(handle)
    end

    # Already a JS value — `to_js` is a no-op pass-through. Lets users
    # write `[hash, array, value].map(&:to_js)` uniformly without
    # special-casing already-wrapped values.
    def to_js
      self
    end

    # Length of an array-like JS value (Array, NodeList, arguments, ...).
    # Reads the `length` property and coerces to int. For Map/Set use
    # `value[:size].to_i` directly since they expose `size`, not `length`.
    def length
      self[:length].to_i
    end
    alias_method :size, :length

    # JS null / undefined detection. BasicObject has no nil?, so define
    # one that reflects the wrapped JS value (== null in JS lands here).
    def nil?
      JSBridge._is_null(handle)
    end

    # JS-side strict equality (===) returning a Ruby boolean.
    # Without this, method_missing would dispatch `==` to JS as a method
    # call (which would either explode or return a JS boolean Value, not
    # a Ruby true/false). Compares wrapped JS values, not handles.
    def ==(other)
      o = JSBridge.wrap(other)
      JSBridge._strict_equal(handle, o.handle)
    end
    alias_method :eql?, :==
    alias_method :equal?, :==

    # JS `typeof` — "object", "string", "function", etc.
    def typeof
      JSBridge._typeof(handle)
    end

    # JS `instance instanceof ctor`. Argument should be a Value wrapping
    # a constructor function. Returns Ruby boolean.
    def instanceof?(ctor)
      JSBridge._instanceof(handle, JSBridge.wrap(ctor).handle)
    end

    # Debug-friendly representation for `p value`. JSON for plain
    # objects/arrays, String() otherwise.
    def inspect
      "#<JSBridge::Value #{JSBridge._inspect(handle)}>"
    end

    # Convert an array-like JS value (anything with a numeric .length and
    # integer-keyed properties — Array, NodeList, arguments, ...) to a
    # Ruby Array of Values.
    def to_a
      len = self[:length].to_i
      Array.new(len) { |i| self[i] }
    end

    # Iterate elements of an array-like JS value. With no block, returns
    # an Enumerator (via Array#each).
    def each(&block)
      return to_a.each unless block
      to_a.each(&block)
      self
    end

    # Adapt the wrapped JS function as a Ruby Proc so it can be passed
    # with `&` to Enumerable methods:
    #   js_upcase = JS.eval("s => s.toUpperCase()")
    #   ["a", "b"].map(&js_upcase)  # => [Value("A"), Value("B")]
    # Implemented via JS Function.prototype.call (`fn.call(null, *args)`).
    def to_proc
      fn = self
      ->(*args) { fn.call(:call, nil, *args) }
    end

    # method_missing forwards everything to JS, so claim we respond to
    # anything. Matches ruby.wasm's JS::Object behaviour. Without this,
    # `obj.respond_to?(:foo)` would itself dispatch to JS as a predicate
    # call (and falsely return false because JS has no `respond_to`).
    def respond_to?(_sym, _include_private = false)
      true
    end

    def respond_to_missing?(_sym, _include_private = false)
      true
    end

    # Subscribe a Ruby block to a JS event (ergonomic alias).
    #   button.on(:click) { |ev| ... }
    # Pass options via the second arg, e.g. JSBridge.object(once: true).
    def on(event, options = nil, &block)
      cb = JSBridge.callback(&block)
      if options
        call(:addEventListener, event.to_s, cb, options)
      else
        call(:addEventListener, event.to_s, cb)
      end
      cb
    end

    # Method-missing: forward unknown method calls to JS.
    #   element.appendChild(child)  →  element.call(:appendChild, child)
    #   list.contains?(item)        →  list.call(:contains, item) → boolean
    def method_missing(sym, *args, &block)
      name = sym.to_s
      if name.end_with?("?")
        result = call(name[0..-2], *args, &block)
        result.to_s == "true"
      elsif name.end_with?("=") && args.size == 1
        self[name[0..-2]] = args.first
      else
        call(sym, *args, &block)
      end
    end
  end

  # Mixin that delegates #to_js to JSBridge.wrap. Included into the
  # standard wrappable classes below so callers can write `hash.to_js`,
  # `[1,2,3].to_js`, `:foo.to_js`, etc. for symmetry with JSBridge::Value#to_js.
  module ToJSMixin
    def to_js
      JSBridge.wrap(self)
    end
  end
end

# Extend the standard Ruby types that JSBridge.wrap handles. Picked to
# match ruby.wasm's Hash/Array/Symbol/etc.#to_js extensions.
[Hash, Array, Symbol, String, Integer, Float, TrueClass, FalseClass, NilClass].each do |klass|
  klass.include(JSBridge::ToJSMixin)
end
