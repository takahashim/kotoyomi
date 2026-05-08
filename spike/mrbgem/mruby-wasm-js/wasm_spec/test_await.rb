

Spec.describe "JS::Object#await (Fiber-based)" do
  Spec.assert "await on Promise.resolve" do
    Spec.assert_equal 42, JS.global[:Promise].resolve(42).await.to_i
  end

  Spec.assert "await chained sequentially" do
    a = JS.global[:Promise].resolve(10).await
    b = JS.global[:Promise].resolve(20).await
    Spec.assert_equal 30, a.to_i + b.to_i
  end

  Spec.assert "await rejected → JS::Error" do
    Spec.assert_raises(JS::Error) do
      JS.global[:Promise].reject(JS.global[:Error].new("rej")).await
    end
  end

  Spec.assert "await string Promise" do
    Spec.assert_equal "hello", JS.global[:Promise].resolve("hello").await.to_s
  end

  Spec.assert "await on real async (setTimeout)" do
    promise = JS.eval(<<~JS)
      new Promise((resolve) => setTimeout(() => resolve("delayed"), 20))
    JS
    Spec.assert_equal "delayed", promise.await.to_s
  end

  Spec.assert "await + chained then in same fiber" do
    p = JS.global[:Promise].resolve(5)
    Spec.assert_equal 5, p.await.to_i
    log = []
    p.then { |v| log << v.to_i }
    JS.global[:Promise].resolve(0).await
    Spec.assert_equal [5], log
  end

  Spec.assert "Promise from object literal" do
    p = JS.eval("Promise.resolve({status: 'ok', code: 200})")
    result = p.await
    Spec.assert_equal "ok", result[:status].to_s
    Spec.assert_equal 200, result[:code].to_i
  end
end
