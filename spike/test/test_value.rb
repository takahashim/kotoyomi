JS = JSBridge

Spec.describe "JSBridge::Value primitives (to_s/i/f, nil?, typeof, etc)" do
  Spec.assert "to_s for number" do
    Spec.assert_equal "42", JS.eval("42").to_s
  end

  Spec.assert "to_s for boolean" do
    Spec.assert_equal "true", JS.eval("true").to_s
  end

  Spec.assert "to_i" do
    Spec.assert_equal 42, JS.eval("42").to_i
    Spec.assert_equal 42, JS.eval("'42'").to_i # JS coerces
  end

  Spec.assert "to_f" do
    Spec.assert_equal 3.14, JS.eval("3.14").to_f
    Spec.assert_equal 0.5, JS.eval("1/2").to_f
  end

  Spec.assert "nil? for null and undefined" do
    Spec.assert_true JS.eval("null").nil?
    Spec.assert_true JS.eval("undefined").nil?
  end

  Spec.assert "nil? false for non-null values" do
    Spec.assert_false JS.eval("0").nil?
    Spec.assert_false JS.eval("''").nil?
    Spec.assert_false JS.eval("false").nil?
  end

  Spec.assert "typeof primitives" do
    Spec.assert_equal "number", JS.eval("42").typeof
    Spec.assert_equal "string", JS.eval("'hi'").typeof
    Spec.assert_equal "boolean", JS.eval("true").typeof
    Spec.assert_equal "function", JS.eval("()=>1").typeof
    Spec.assert_equal "object", JS.eval("[]").typeof
    Spec.assert_equal "object", JS.eval("({})").typeof
    Spec.assert_equal "object", JS.eval("null").typeof # JS quirk
  end

  Spec.assert "instanceof? for arrays" do
    arr = JS.eval("[1,2,3]")
    Spec.assert_true arr.instanceof?(JS.global[:Array])
    Spec.assert_false arr.instanceof?(JS.global[:Date])
  end

  Spec.assert "== compares JS values strictly" do
    Spec.assert_true JS.eval("42") == JS.eval("42")
    Spec.assert_false JS.eval("42") == JS.eval("'42'") # === is strict
  end

  Spec.assert "== with auto-wrap on right side" do
    Spec.assert_true JS.eval("42") == 42
    Spec.assert_true JS.eval("'hi'") == "hi"
  end

  Spec.assert "eql? alias of ==" do
    Spec.assert_true JS.eval("42").eql?(JS.eval("42"))
  end

  Spec.assert "inspect shows JSON-ish form" do
    Spec.assert_true JS.eval("42").inspect.include?("42")
    Spec.assert_true JS.eval("'hi'").inspect.include?('"hi"')
    Spec.assert_true JS.eval("[1,2]").inspect.include?("[1,2]")
  end

  Spec.assert "respond_to? always true" do
    v = JS.eval("({})")
    Spec.assert_true v.respond_to?(:anything)
    Spec.assert_true v.respond_to?(:foo_bar)
  end
end
