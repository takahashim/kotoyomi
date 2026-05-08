# Tests for mruby-wasi-env. The runner pre-populates the host env
# object before boot:
#   env.SPEC_RUNNER = "wasm_spec"
# wasi-libc reads the environ via the WASI environ_get import, so
# ENV["SPEC_RUNNER"] surfaces it on the Ruby side.

Spec.describe "ENV[]" do
  Spec.assert "host-supplied vars are visible after boot" do
    Spec.assert_equal "wasm_spec", ENV["SPEC_RUNNER"]
  end

  Spec.assert "missing key returns nil" do
    Spec.assert_equal nil, ENV["NO_SUCH_VAR"]
  end
end

Spec.describe "ENV[]= / store / delete" do
  Spec.assert "set + read round-trip" do
    ENV["TEST_KEY"] = "test_value"
    Spec.assert_equal "test_value", ENV["TEST_KEY"]
    ENV.delete("TEST_KEY")
  end

  Spec.assert "store is an alias for []=" do
    ENV.store("STORED_KEY", "stored")
    Spec.assert_equal "stored", ENV["STORED_KEY"]
    ENV.delete("STORED_KEY")
  end

  Spec.assert "set to nil unsets" do
    ENV["TO_UNSET"] = "x"
    Spec.assert_equal "x", ENV["TO_UNSET"]
    ENV["TO_UNSET"] = nil
    Spec.assert_equal nil, ENV["TO_UNSET"]
  end

  Spec.assert "delete returns the previous value" do
    ENV["TO_DELETE"] = "doomed"
    Spec.assert_equal "doomed", ENV.delete("TO_DELETE")
    Spec.assert_equal nil, ENV["TO_DELETE"]
  end

  Spec.assert "delete on missing key returns nil" do
    Spec.assert_equal nil, ENV.delete("NEVER_SET")
  end
end

Spec.describe "ENV introspection" do
  Spec.assert "key? for existing var" do
    Spec.assert_true ENV.key?("SPEC_RUNNER")
  end

  Spec.assert "key? for missing var" do
    Spec.assert_false ENV.key?("NO_SUCH_VAR")
  end

  Spec.assert "include? alias" do
    Spec.assert_true ENV.include?("SPEC_RUNNER")
  end

  Spec.assert "keys includes host-supplied vars" do
    Spec.assert_true ENV.keys.include?("SPEC_RUNNER")
  end

  Spec.assert "values reflects what's in keys" do
    Spec.assert_equal ENV.keys.length, ENV.values.length
  end

  Spec.assert "to_h returns a real Hash" do
    h = ENV.to_h
    Spec.assert_equal Hash, h.class
    Spec.assert_equal "wasm_spec", h["SPEC_RUNNER"]
  end

  Spec.assert "size matches keys.length" do
    Spec.assert_equal ENV.keys.length, ENV.size
  end

  Spec.assert "empty? is false when host populated env" do
    Spec.assert_false ENV.empty?
  end
end

Spec.describe "ENV iteration" do
  Spec.assert "each yields key, value pairs" do
    pairs = []
    ENV.each { |k, v| pairs << [k, v] }
    spec_pair = pairs.find { |k, _| k == "SPEC_RUNNER" }
    Spec.assert_equal "wasm_spec", spec_pair[1]
  end

  Spec.assert "each_key yields keys" do
    seen = []
    ENV.each_key { |k| seen << k }
    Spec.assert_true seen.include?("SPEC_RUNNER")
  end

  Spec.assert "each_value yields values" do
    seen = []
    ENV.each_value { |v| seen << v }
    Spec.assert_true seen.include?("wasm_spec")
  end
end

Spec.describe "ENV.fetch" do
  Spec.assert "returns the value for an existing key" do
    Spec.assert_equal "wasm_spec", ENV.fetch("SPEC_RUNNER")
  end

  Spec.assert "returns the default for a missing key" do
    Spec.assert_equal "fallback", ENV.fetch("NO_SUCH", "fallback")
  end

  Spec.assert "yields to the block for a missing key" do
    Spec.assert_equal "computed", ENV.fetch("NO_SUCH") { |k| "computed" }
  end

  Spec.assert "raises KeyError for a missing key with no default or block" do
    Spec.assert_raises(KeyError) { ENV.fetch("NO_SUCH") }
  end
end

Spec.describe "ENV.values_at" do
  Spec.assert "returns values in order" do
    ENV["VK1"] = "one"
    ENV["VK2"] = "two"
    Spec.assert_equal ["one", "two", nil], ENV.values_at("VK1", "VK2", "MISSING")
    ENV.delete("VK1")
    ENV.delete("VK2")
  end
end
