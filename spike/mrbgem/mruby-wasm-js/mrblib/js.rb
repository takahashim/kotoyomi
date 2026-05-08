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
  # JSBridge::Error is defined in C (extends StandardError). Reopen it
  # here to expose the original JS Error object via #js_value, attached
  # by raise_if_js_error in C. Lets users read .name / .stack / .cause:
  #   rescue JSBridge::Error => e
  #     puts e.js_value[:name].to_s   # => "TypeError"
  #     puts e.js_value[:stack].to_s  # => "TypeError: ...\n  at ..."
  class Error
    attr_reader :js_value
  end

  # Ivars on the JSBridge module itself (not its singleton class) — must
  # be initialised here in module body so the class-method readers below
  # see the same object.
  @await_fibers = {}
  @await_next_id = 0
  # Maps a callback Value's JS handle → C-side callback id. Lets
  # release_callback look up the id without storing it on the Value
  # object (Value < BasicObject, no friendly ivar story).
  @callback_ids = {}

  class << self
    def global
      Value.new(_global)
    end

    def eval(src)
      Value.new(_eval(src))
    end

    # Wrap a Ruby block as a JS callback function.
    # Returns a Value holding the JS wrapper. The Proc is registered in
    # the C-side callback table; release_callback frees it explicitly,
    # otherwise it lives for the lifetime of the VM.
    def callback(&block)
      raise ArgumentError, "block required" unless block
      handle, id = _make_callback(block)
      @callback_ids[handle] = id
      Value.new(handle)
    end

    # Snapshot of bridge resource usage. Useful for spotting leaks during
    # development:
    #
    #   before = JSBridge.stats
    #   1000.times { ... }
    #   after = JSBridge.stats
    #   p (after[:handles] - before[:handles])    # JS handles still alive
    #   p (after[:callbacks] - before[:callbacks]) # registered Procs
    #
    # Counts are absolute (cumulative since boot), not deltas.
    def stats
      {
        handles: _handle_count,           # JS-side handle table size
        callbacks: _callback_count,       # C-side callback Hash size
        await_fibers: @await_fibers.size, # suspended fibers waiting on .await
        callback_ids: @callback_ids.size, # Ruby-side handle→cb_id map
      }
    end

    # Release a callback's Proc from the C-side table so it (and anything
    # the block closes over) can be GC'd. Idempotent. Use for one-shot
    # callbacks where you know the JS side will only invoke the wrapper
    # once (Value#await uses this internally to free the unfired half of
    # its (then, catch) pair).
    def release_callback(cb_value)
      return if cb_value.nil?
      handle = cb_value.handle
      id = @callback_ids.delete(handle)
      _release_callback(id) if id
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

    # Non-raising variant of #wrap. Returns the wrapped Value if the
    # argument is convertible (one of the types #wrap recognises), or
    # `nil` if it isn't. Useful for libraries that want to optionally
    # accept JS values:
    #   if (jsv = JSBridge.try_convert(arg)); use_as_js(jsv); ...
    def try_convert(v)
      wrap(v)
    rescue ArgumentError
      nil
    end

    # Internal: top-level entry-point used by js_bridge_eval_handle to
    # wrap user source in a Fiber. Without this, `Value#await` has no
    # parent fiber to yield to. The block runs immediately; if it
    # `await`s anywhere, the fiber yields and gets resumed later via
    # a Promise .then callback (see Value#await).
    def __run_in_fiber__(&block)
      ::Fiber.new(&block).resume
    end

    # Internal fiber registry for await. Maps id → Fiber. The .then /
    # .catch callbacks Value#await registers capture only the integer id
    # (not the Fiber itself), so once we delete the entry here, the
    # Fiber becomes eligible for GC. Without this, dead-fiber references
    # leaked through callback closures cause GC mark crashes when their
    # internal stacks have been torn down.
    # (Ivar storage is on the JSBridge module — see top of file.)

    def __register_await_fiber__(fiber)
      id = (@await_next_id += 1)
      @await_fibers[id] = fiber
      id
    end

    # Resume the fiber registered with `id`. Removes it from the registry
    # so the second of the (then-onFulfilled, then-onRejected) pair becomes
    # a no-op once the first has fired.
    def __resume_await_fiber__(id, status_value)
      fiber = @await_fibers.delete(id)
      return if fiber.nil? || !fiber.alive?
      fiber.resume(status_value)
    end

    # Internal helper shared by Value#call / Value#new. Wraps each
    # positional arg as a Value, hands the resulting handle list to the
    # block (which performs the actual WASM dispatch), and wraps the
    # returned handle as a Value.
    #
    # `wrapped` stays as a local variable across the yield so mruby's GC
    # cannot release the temporary Values between handle extraction and
    # the WASM call (we hit this exact bug in Phase 2b).
    def __invoke_with_handles__(args)
      wrapped = args.map { |a| wrap(a) }
      handles = wrapped.map(&:handle)
      result_handle = yield handles
      wrapped # explicit reference so the array survives the yield above
      Value.new(result_handle)
    end
  end

  class Value
    # `initialize(handle)` and `handle` are defined in C.
    # Inherits from BasicObject — only define what we actually need.
    # method_missing falls back to JS dispatch, so the surface here is
    # focused on (a) ergonomic conveniences and (b) escapes from
    # accidental JS dispatch (e.g. `==`, `nil?`).

    # ---------- Property access ----------

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

    # ---------- Invocation ----------

    # Call a JS method. If a block is given, it's wrapped as a JS callback
    # and appended as the last argument (ruby.wasm convention).
    def call(method, *args, &block)
      args = args + [JSBridge.callback(&block)] if block
      JSBridge.__invoke_with_handles__(args) do |handles|
        JSBridge._call(handle, method.to_s, handles)
      end
    end

    # Call as a JS constructor: `Foo.new(args)` → `new Foo(args)`.
    def new(*args)
      JSBridge.__invoke_with_handles__(args) do |handles|
        JSBridge._new(handle, handles)
      end
    end

    # Call a JS method with arguments from an Array. Mirrors ruby.wasm's
    # JS::Object#apply (and JS's Function.prototype.apply semantics — the
    # array is spread as positional args, not passed as a single arg).
    def apply(method, args_array, &block)
      call(method, *args_array, &block)
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

    # method_missing: forward unknown method calls to JS.
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

    # ---------- Conversion ----------

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

    # Adapt the wrapped JS function as a Ruby Proc so it can be passed
    # with `&` to Enumerable methods:
    #   js_upcase = JS.eval("s => s.toUpperCase()")
    #   ["a", "b"].map(&js_upcase)  # => [Value("A"), Value("B")]
    # Implemented via JS Function.prototype.call (`fn.call(null, *args)`).
    def to_proc
      fn = self
      ->(*args) { fn.call(:call, nil, *args) }
    end

    # ---------- Iteration ----------

    # Length of an array-like JS value (Array, NodeList, arguments, ...).
    # Reads the `length` property and coerces to int. For Map/Set use
    # `value[:size].to_i` directly since they expose `size`, not `length`.
    def length
      self[:length].to_i
    end
    alias_method :size, :length

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

    # ---------- Equality ----------

    # JS-side strict equality (===) returning a Ruby boolean.
    # Without this, method_missing would dispatch `==` to JS as a method
    # call (which would either explode or return a JS boolean Value, not
    # a Ruby true/false). Compares wrapped JS values, not handles.
    def ==(other)
      o = JSBridge.wrap(other)
      JSBridge._strict_equal(handle, o.handle)
    end
    alias_method :eql?, :==
    # `equal?` deliberately NOT aliased to `==` — Ruby convention reserves
    # `equal?` for object-identity checks ("same Ruby object"), which is
    # different from "same JS value". BasicObject's default equal? gives
    # the right semantics (pointer identity), so we leave it inherited.

    # ---------- Type queries ----------

    # JS null / undefined detection. BasicObject has no nil?, so define
    # one that reflects the wrapped JS value (== null in JS lands here).
    def nil?
      JSBridge._is_null(handle)
    end

    # JS `typeof` — "object", "string", "function", etc.
    def typeof
      JSBridge._typeof(handle)
    end

    # JS `instance instanceof ctor`. Argument should be a Value wrapping
    # a constructor function. Returns Ruby boolean.
    def instanceof?(ctor)
      JSBridge._instanceof(handle, JSBridge.wrap(ctor).handle)
    end

    # method_missing forwards everything to JS, so claim we respond to
    # anything. Matches ruby.wasm's JS::Object behaviour. Without this,
    # `obj.respond_to?(:foo)` would itself dispatch to JS as a predicate
    # call (and falsely return false because JS has no `respond_to`).
    def respond_to?(_sym, _include_private = false)
      true
    end

    # mruby auto-marks respond_to_missing? as private (matches Ruby
    # convention). Used as the introspection hook by mruby-method even
    # though our explicit respond_to? above already covers the public path.
    def respond_to_missing?(_sym, _include_private = false)
      true
    end

    # ---------- Async ----------

    # Block until the wrapped Promise settles, then return its resolved
    # value (or raise JSBridge::Error if it rejected). Implemented via
    # mruby Fibers — the calling fiber yields after registering .then /
    # .catch handlers; those handlers resume the fiber once the Promise
    # fires. Top-level eval is auto-wrapped in a Fiber by
    # js_bridge_eval_handle, so `value.await` "just works" at top level.
    #
    # Note: this is functionally equivalent to ruby.wasm's `await` but
    # built on Fiber instead of Asyncify. Stack frames across the await
    # boundary are split (the post-await continuation runs from a
    # different host re-entry).
    #
    # Implementation note: the .then/.catch callbacks intentionally
    # capture only an integer fid (registered in JSBridge's fiber table),
    # not the Fiber itself. The C-side callback table never reclaims
    # entries, so closing over a Fiber would keep its (post-termination,
    # potentially torn-down) state alive and crash the GC mark phase.
    def await
      fid = ::JSBridge.__register_await_fiber__(::Fiber.current)
      on_ok = on_err = nil
      release_pair = -> {
        ::JSBridge.release_callback(on_ok)
        ::JSBridge.release_callback(on_err)
      }
      on_ok = ::JSBridge.callback do |val|
        release_pair.call
        ::JSBridge.__resume_await_fiber__(fid, [:ok, val])
      end
      on_err = ::JSBridge.callback do |err|
        release_pair.call
        ::JSBridge.__resume_await_fiber__(fid, [:error, err])
      end
      call(:then, on_ok, on_err)
      status, value = __yield_for_await__
      ::Kernel.raise(::JSBridge::Error, value.to_s) if status == :error
      value
    end

    # Suspend the current fiber waiting for an await callback. Returns
    # the [:ok, val] / [:error, err] tuple the resumer passed back.
    # If the caller wasn't running in a Fiber (e.g. someone wrapped
    # something other than a top-level evalRuby), Fiber.yield raises
    # FiberError; we surface that as a NotImplementedError with a hint.
    def __yield_for_await__
      ::Fiber.yield
    rescue ::FiberError
      ::Kernel.raise(
        ::NotImplementedError,
        "JSBridge::Value#await must run inside a Fiber. " \
        "Top-level evalRuby is auto-wrapped; if you spawn your own " \
        "task, use JSBridge.__run_in_fiber__ { ... } around it.",
      )
    end

    # ---------- Debug ----------

    # Debug-friendly representation for `p value`. JSON for plain
    # objects/arrays, String() otherwise.
    def inspect
      "#<JSBridge::Value #{JSBridge._inspect(handle)}>"
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
