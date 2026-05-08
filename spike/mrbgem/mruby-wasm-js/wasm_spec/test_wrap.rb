

Spec.describe "JS.wrap / try_convert / object / array / #to_js" do
  Spec.assert "wrap Integer" do
    Spec.assert_equal 42, JS.wrap(42).to_i
  end

  Spec.assert "wrap Float" do
    Spec.assert_equal 3.14, JS.wrap(3.14).to_f
  end

  Spec.assert "wrap String" do
    Spec.assert_equal "hi", JS.wrap("hi").to_s
  end

  Spec.assert "wrap Symbol → JS string" do
    Spec.assert_equal "foo", JS.wrap(:foo).to_s
    Spec.assert_equal "string", JS.wrap(:foo).typeof
  end

  Spec.assert "wrap nil → null" do
    Spec.assert_true JS.wrap(nil).nil?
  end

  Spec.assert "wrap true / false" do
    Spec.assert_equal "true", JS.wrap(true).to_s
    Spec.assert_equal "false", JS.wrap(false).to_s
  end

  Spec.assert "wrap Array → JS array" do
    a = JS.wrap([1, 2, 3])
    Spec.assert_equal 3, a.length
    Spec.assert_equal 1, a[0].to_i
  end

  Spec.assert "wrap Hash → JS object literal" do
    h = JS.wrap(once: true, capture: false)
    Spec.assert_equal "true", h[:once].to_s
    Spec.assert_equal "false", h[:capture].to_s
  end

  Spec.assert "wrap Hash recursively" do
    h = JS.wrap(opts: { once: true })
    Spec.assert_equal "true", h[:opts][:once].to_s
  end

  Spec.assert "wrap JS::Object passes through" do
    v = JS.eval("42")
    Spec.assert_true v == JS.wrap(v)
  end

  Spec.assert "wrap raises for unsupported types" do
    Spec.assert_raises(ArgumentError) { JS.wrap(Object.new) }
  end

  Spec.assert "try_convert returns nil for unsupported" do
    Spec.assert_equal nil, JS.try_convert(Object.new)
  end

  Spec.assert "try_convert wraps known types" do
    Spec.assert_equal 42, JS.try_convert(42).to_i
  end

  Spec.assert "JS.object" do
    obj = JS.object(once: true)
    Spec.assert_equal "true", obj[:once].to_s
  end

  Spec.assert "JS.array" do
    arr = JS.array([10, 20, 30])
    Spec.assert_equal 3, arr.length
    Spec.assert_equal 20, arr[1].to_i
  end

  Spec.assert "Hash#to_js" do
    Spec.assert_equal "true", { once: true }.to_js[:once].to_s
  end

  Spec.assert "Array#to_js" do
    Spec.assert_equal 3, [1, 2, 3].to_js.length
  end

  Spec.assert "Symbol#to_js" do
    Spec.assert_equal "foo", :foo.to_js.to_s
  end

  Spec.assert "Integer#to_js" do
    Spec.assert_equal 42, 42.to_js.to_i
  end

  Spec.assert "JS::Object#to_js is identity" do
    v = JS.eval("[]")
    Spec.assert_true v.equal?(v.to_js)
  end

  Spec.assert "[]= with Hash on the right" do
    target = JS.eval("({})")
    target[:opts] = { once: true }
    Spec.assert_equal "true", target[:opts][:once].to_s
  end

  Spec.assert "[]= with Array on the right" do
    target = JS.eval("({})")
    target[:items] = [1, 2, 3]
    Spec.assert_equal 3, target[:items].length
  end
end
