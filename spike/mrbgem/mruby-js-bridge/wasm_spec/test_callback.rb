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
end
