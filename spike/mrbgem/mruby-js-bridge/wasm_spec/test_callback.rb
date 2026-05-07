JS = JSBridge

Spec.describe "block-as-callback / on / then" do
  Spec.assert "addEventListener via call dispatches block" do
    target = JS.eval("new EventTarget()")
    fired = []
    cb = target.on(:tick) { |_ev| fired << :hit }
    target.dispatchEvent(JS.eval("new Event('tick')"))
    target.dispatchEvent(JS.eval("new Event('tick')"))
    Spec.assert_equal 2, fired.length
    cb # keep alive — referenced for GC rooting via @callbacks pattern
  end

  Spec.assert "on with options { once: true } fires only once" do
    target = JS.eval("new EventTarget()")
    fired = 0
    target.on(:tick, JS.object(once: true)) { |_ev| fired += 1 }
    target.dispatchEvent(JS.eval("new Event('tick')"))
    target.dispatchEvent(JS.eval("new Event('tick')"))
    Spec.assert_equal 1, fired
  end

  Spec.assert "callback receives event arg as Value" do
    target = JS.eval("new EventTarget()")
    captured_type = nil
    target.on(:hello) { |ev| captured_type = ev[:type].to_s }
    target.dispatchEvent(JS.eval("new Event('hello')"))
    Spec.assert_equal "hello", captured_type
  end

  Spec.assert "Promise.then via method_missing with block" do
    log = []
    JS.global[:Promise].resolve(7).then { |v| log << v.to_i }
    # then is async — wait for microtask. We schedule another microtask
    # via Promise.resolve and await it to observe the prior microtask.
    JS.global[:Promise].resolve(0).await
    Spec.assert_equal [7], log
  end

  Spec.assert "JSBridge.callback wraps block as JS function" do
    cb = JS.callback { 42 }
    Spec.assert_equal "function", cb.typeof
  end

  Spec.assert "JSBridge.callback raises without a block" do
    Spec.assert_raises(ArgumentError) { JS.callback }
  end

  Spec.assert "release_callback removes the Proc from C-side table" do
    before = JS._callback_count
    cb = JS.callback { 99 }
    after_make = JS._callback_count
    JS.release_callback(cb)
    after_release = JS._callback_count
    Spec.assert_equal before + 1, after_make
    Spec.assert_equal before, after_release
  end

  Spec.assert "release_callback is idempotent + nil-safe" do
    cb = JS.callback { 1 }
    JS.release_callback(cb)
    JS.release_callback(cb)
    JS.release_callback(nil)
    Spec.assert_true true
  end

  Spec.assert "await releases both then/catch callbacks after settle" do
    before = JS._callback_count
    JS.global[:Promise].resolve(1).await
    # Let the post-await microtask flush so any straggler release runs.
    JS.global[:Promise].resolve(0).await
    after = JS._callback_count
    # Each await registers 2 callbacks; both should be released.
    # Tolerate +2 for the trailing flush await's pair (its release
    # callbacks haven't fired by the time we sample after).
    Spec.assert_true(after <= before + 2,
      "callback table grew: before=#{before}, after=#{after}")
  end
end
