JS = JSBridge

Spec.describe "JSBridge::Error propagation" do
  Spec.assert "JSBridge::Error inherits StandardError" do
    Spec.assert_true JSBridge::Error < StandardError
  end

  Spec.assert "eval throw → JSBridge::Error" do
    err = Spec.assert_raises(JSBridge::Error) do
      JS.eval("(()=>{ throw new Error('boom') })()")
    end
    Spec.assert_true err.message.include?("boom")
  end

  Spec.assert "method call throw → JSBridge::Error" do
    Spec.assert_raises(JSBridge::Error) do
      JS.eval("[]").nope_does_not_exist
    end
  end

  Spec.assert "constructor throw → JSBridge::Error" do
    Spec.assert_raises(JSBridge::Error) do
      JS.global[:Date].new(JS.eval("(()=>{throw new Error('ctor exp')})()"))
    end
  end

  Spec.assert "[] on null → JSBridge::Error" do
    Spec.assert_raises(JSBridge::Error) do
      JS.eval("null")[:foo]
    end
  end

  Spec.assert "[]= on null → JSBridge::Error" do
    Spec.assert_raises(JSBridge::Error) do
      JS.eval("null")[:foo] = 1
    end
  end

  Spec.assert "system continues to work after caught error" do
    begin
      JS.eval("(()=>{throw new Error('x')})()")
    rescue JSBridge::Error
      # expected
    end
    Spec.assert_equal 4, JS.eval("2 + 2").to_i
  end

  Spec.assert "error state cleared between calls" do
    # First triggers + rescues; second should not see the prior error.
    begin
      JS.eval("(()=>{throw new Error('first')})()")
    rescue JSBridge::Error
      # expected
    end
    Spec.assert_equal "ok", JS.eval("'ok'").to_s
  end
end
