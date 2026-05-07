JS = JSBridge

Spec.describe "JSBridge::Value#call / #apply / method_missing" do
  Spec.assert "call returns a Value" do
    arr = JS.eval("[1, 2, 3]")
    result = arr.call(:concat, JS.eval("[4, 5]"))
    Spec.assert_equal 5, result.length
  end

  Spec.assert "method_missing dispatches to JS" do
    str = JS.eval("'  hello  '")
    Spec.assert_equal "hello", str.trim.to_s
  end

  Spec.assert "predicate ? returns Ruby boolean" do
    arr = JS.eval("[1, 2, 3]")
    Spec.assert_true arr.includes?(2)
    Spec.assert_false arr.includes?(99)
  end

  Spec.assert "name= dispatches as []=" do
    obj = JS.eval("({})")
    obj.title = "via setter"
    Spec.assert_equal "via setter", obj[:title].to_s
  end

  Spec.assert "method chaining" do
    Spec.assert_equal "ABC", JS.eval("'abc'").toUpperCase.to_s
  end

  Spec.assert "apply with array of args" do
    math = JS.global[:Math]
    Spec.assert_equal 9, math.apply(:max, [3, 1, 4, 1, 5, 9, 2, 6]).to_i
  end

  Spec.assert "apply with empty array" do
    arr = JS.eval('[]')
    Spec.assert_equal "", arr.apply(:toString, []).to_s
  end

  Spec.assert "call accepts splat" do
    math = JS.global[:Math]
    Spec.assert_equal 9, math.max(*[3, 1, 4, 1, 5, 9, 2, 6]).to_i
  end

  Spec.assert "call dispatches block-as-callback" do
    arr = JS.eval("[10, 20, 30]")
    sum = 0
    arr.forEach { |v| sum += v.to_i }
    Spec.assert_equal 60, sum
  end
end
