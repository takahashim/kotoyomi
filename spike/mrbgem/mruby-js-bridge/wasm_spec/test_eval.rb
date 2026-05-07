JS = JSBridge

Spec.describe "JSBridge.eval / global / property access" do
  Spec.assert "eval returns Value with int" do
    Spec.assert_equal 42, JS.eval("42").to_i
  end

  Spec.assert "eval returns Value with string" do
    Spec.assert_equal "hi", JS.eval("'hi'").to_s
  end

  Spec.assert "eval returns Value with float" do
    Spec.assert_equal 3.14, JS.eval("3.14").to_f
  end

  Spec.assert "eval returns Value with null" do
    Spec.assert_true JS.eval("null").nil?
  end

  Spec.assert "eval returns Value with undefined" do
    Spec.assert_true JS.eval("undefined").nil?
  end

  Spec.assert "JSBridge.global is the JS globalThis" do
    g = JS.global
    Spec.assert_false g.nil?
    Spec.assert_equal "object", g.typeof
  end

  Spec.assert "global property access via []" do
    Spec.assert_equal "object", JS.global[:Math].typeof
  end

  Spec.assert "global property access with string key" do
    Spec.assert_equal "object", JS.global["Math"].typeof
  end

  Spec.assert "deep property access" do
    pi = JS.global[:Math][:PI].to_f
    Spec.assert_true pi > 3.14
    Spec.assert_true pi < 3.15
  end

  Spec.assert "[]= sets a property" do
    obj = JS.eval("({})")
    obj[:foo] = 123
    Spec.assert_equal 123, obj[:foo].to_i
  end

  Spec.assert "[]= with string value" do
    obj = JS.eval("({})")
    obj[:name] = "alice"
    Spec.assert_equal "alice", obj[:name].to_s
  end
end
