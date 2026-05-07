JS = JSBridge

Spec.describe "JSBridge::Value#new (constructor invocation)" do
  Spec.assert "new Date" do
    d = JS.global[:Date].new(2026, 4, 8) # JS month is 0-indexed: 4 = May
    Spec.assert_equal 2026, d.getFullYear.to_i
    Spec.assert_equal 4, d.getMonth.to_i
    Spec.assert_equal 8, d.getDate.to_i
  end

  Spec.assert "new Map" do
    m = JS.global[:Map].new
    m.set("a", 1)
    m.set("b", 2)
    Spec.assert_equal 2, m[:size].to_i
    Spec.assert_equal 1, m.get("a").to_i
  end

  Spec.assert "new Set" do
    s = JS.global[:Set].new
    s.add(1)
    s.add(1)
    s.add(2)
    Spec.assert_equal 2, s[:size].to_i
  end

  Spec.assert "new Error" do
    err = JS.global[:Error].new("oops")
    Spec.assert_equal "oops", err[:message].to_s
  end

  Spec.assert "new on non-function raises JSBridge::Error" do
    Spec.assert_raises(JSBridge::Error) do
      JS.eval("42").new
    end
  end

  Spec.assert "new with no args" do
    obj = JS.global[:Object].new
    Spec.assert_equal "object", obj.typeof
  end
end
