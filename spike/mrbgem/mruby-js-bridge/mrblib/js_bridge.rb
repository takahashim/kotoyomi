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
    def wrap(v)
      case v
      when Value then v
      when Integer then Value.new(_from_int(v))
      when Float then Value.new(_from_float(v))
      when String then Value.new(_from_string(v))
      when nil then Value.new(_eval("null"))
      when true then Value.new(_eval("true"))
      when false then Value.new(_eval("false"))
      else
        raise ArgumentError, "cannot wrap #{v.class} as JS value"
      end
    end

    # Build a JS object literal from a Ruby Hash.
    # Useful for `addEventListener`'s options arg, etc.:
    #   JSBridge.object(once: true)  →  { once: true }
    def object(hash = {})
      obj = eval("({})")
      hash.each { |k, v| obj[k] = v }
      obj
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

    def to_s
      JSBridge._to_string(handle)
    end

    def to_i
      JSBridge._to_int(handle)
    end

    def to_f
      JSBridge._to_float(handle)
    end

    # JS null / undefined detection. BasicObject has no nil?, so define
    # one that reflects the wrapped JS value (== null in JS lands here).
    def nil?
      JSBridge._is_null(handle)
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
end
