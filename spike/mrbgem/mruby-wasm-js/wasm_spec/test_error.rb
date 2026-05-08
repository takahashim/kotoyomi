

Spec.describe "JS::Error propagation" do
  Spec.assert "JS::Error inherits StandardError" do
    Spec.assert_true JS::Error < StandardError
  end

  Spec.assert "Error#js_value exposes original JS Error object" do
    err = Spec.assert_raises(JS::Error) do
      JS.eval("(()=>{ throw new TypeError('typed') })()")
    end
    Spec.assert_equal "TypeError", err.js_value[:name].to_s
    Spec.assert_equal "typed", err.js_value[:message].to_s
  end

  Spec.assert "Error#js_value preserves custom attributes" do
    err = Spec.assert_raises(JS::Error) do
      JS.eval("(()=>{ const e = new Error('x'); e.code = 'OOPS'; throw e })()")
    end
    Spec.assert_equal "OOPS", err.js_value[:code].to_s
  end

  Spec.assert "non-Error throw gets wrapped" do
    err = Spec.assert_raises(JS::Error) do
      JS.eval("(()=>{ throw 42 })()")
    end
    Spec.assert_equal "Error", err.js_value[:name].to_s
    Spec.assert_equal "42", err.message
  end

  Spec.assert "eval throw → JS::Error" do
    err = Spec.assert_raises(JS::Error) do
      JS.eval("(()=>{ throw new Error('boom') })()")
    end
    Spec.assert_true err.message.include?("boom")
  end

  Spec.assert "method call throw → JS::Error" do
    Spec.assert_raises(JS::Error) do
      JS.eval("[]").nope_does_not_exist
    end
  end

  Spec.assert "constructor throw → JS::Error" do
    Spec.assert_raises(JS::Error) do
      JS.global[:Date].new(JS.eval("(()=>{throw new Error('ctor exp')})()"))
    end
  end

  Spec.assert "[] on null → JS::Error" do
    Spec.assert_raises(JS::Error) do
      JS.eval("null")[:foo]
    end
  end

  Spec.assert "[]= on null → JS::Error" do
    Spec.assert_raises(JS::Error) do
      JS.eval("null")[:foo] = 1
    end
  end

  Spec.assert "system continues to work after caught error" do
    begin
      JS.eval("(()=>{throw new Error('x')})()")
    rescue JS::Error
      # expected
    end
    Spec.assert_equal 4, JS.eval("2 + 2").to_i
  end

  Spec.assert "error state cleared between calls" do
    # First triggers + rescues; second should not see the prior error.
    begin
      JS.eval("(()=>{throw new Error('first')})()")
    rescue JS::Error
      # expected
    end
    Spec.assert_equal "ok", JS.eval("'ok'").to_s
  end
end
