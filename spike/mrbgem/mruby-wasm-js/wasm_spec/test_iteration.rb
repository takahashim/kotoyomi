

Spec.describe "iteration: to_a / each / to_proc / length / size" do
  Spec.assert "length returns Ruby Integer" do
    Spec.assert_equal 3, JS.eval("[1,2,3]").length
  end

  Spec.assert "size is alias of length" do
    Spec.assert_equal 4, JS.eval("[10,20,30,40]").size
  end

  Spec.assert "to_a returns Ruby Array of JS::Objects" do
    arr = JS.eval('["a", "b", "c"]').to_a
    Spec.assert_equal Array, arr.class
    Spec.assert_equal 3, arr.length
    Spec.assert_equal "a", arr[0].to_s
  end

  Spec.assert "to_a on array-like (length + integer keys)" do
    pseudo = JS.eval('({length: 2, 0: "x", 1: "y"})')
    arr = pseudo.to_a
    Spec.assert_equal 2, arr.length
    Spec.assert_equal "y", arr[1].to_s
  end

  Spec.assert "each iterates" do
    sum = 0
    JS.eval("[10, 20, 30]").each { |v| sum += v.to_i }
    Spec.assert_equal 60, sum
  end

  Spec.assert "each with no block returns Enumerator" do
    e = JS.eval("[1,2,3]").each
    # Just verify it's enumerable; iteration is via to_a.each
    Spec.assert_equal 6, e.reduce(0) { |a, v| a + v.to_i }
  end

  Spec.assert "to_proc enables &fn for Enumerable" do
    upcase = JS.eval("s => s.toUpperCase()")
    result = ["foo", "bar"].map(&upcase)
    Spec.assert_equal "FOO", result[0].to_s
    Spec.assert_equal "BAR", result[1].to_s
  end

  Spec.assert "to_proc with multi-arg JS function" do
    add = JS.eval("(a, b) => a + b")
    Spec.assert_equal 7, add.to_proc.call(3, 4).to_i
  end
end
