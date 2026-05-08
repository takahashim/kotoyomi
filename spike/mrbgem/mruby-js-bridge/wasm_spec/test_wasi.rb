# Tests for the WASI imports the host adapter provides:
#   clock_time_get / clock_res_get  →  Time.now
#   random_get                       →  Random#bytes / rand
#   environ_get / environ_sizes_get  → (ENV not in core mruby; verified via runner)
#   filesystem (path_open / fd_read / fd_close / fd_seek / fd_filestat_get,
#                 path_filestat_get) →  File.read / File.open
#
# spec_helper exports `JS = JSBridge`; here we just exercise the Ruby
# stdlib paths that wasi-libc routes through our imports.

Spec.describe "WASI: clock_time_get → Time.now" do
  Spec.assert "Time.now returns a Time" do
    Spec.assert_equal Time, Time.now.class
  end

  Spec.assert "Time.now is a plausible epoch (>= 2024-01-01)" do
    Spec.assert_true Time.now.to_i >= 1_704_067_200
  end

  Spec.assert "successive Time.now calls are monotonic-ish" do
    a = Time.now.to_f
    100.times { } # do something cheap
    b = Time.now.to_f
    Spec.assert_true b >= a
  end
end

Spec.describe "WASI: random_get → Random / rand" do
  Spec.assert "rand(N) returns Integer in range" do
    v = rand(1000)
    Spec.assert_equal Integer, v.class
    Spec.assert_true v >= 0
    Spec.assert_true v < 1000
  end

  Spec.assert "two rand() calls give different results (probabilistically)" do
    samples = Array.new(20) { rand(1_000_000) }
    Spec.assert_true samples.uniq.length > 1
  end

  Spec.assert "Random.new.bytes(N) has correct length" do
    bytes = Random.new.bytes(16)
    Spec.assert_equal 16, bytes.bytesize
  end
end

Spec.describe "WASI: stdin → STDIN.read / .gets" do
  Spec.assert "STDIN.read consumes the host-provided buffer" do
    # The runner pre-pushes "stdin payload\n" via stdin.pushText().
    # Note: STDIN is a single shared resource — first read consumes,
    # subsequent reads see EOF.
    s = STDIN.read
    Spec.assert_equal "stdin payload\n", s
  end

  Spec.assert "STDIN.read after exhaustion returns ''" do
    Spec.assert_equal "", STDIN.read
  end
end

Spec.describe "WASI: args → ARGV" do
  Spec.assert "ARGV is populated from JS-side args" do
    # The runner sets `args.push("--smoke", "test_wasi", "fixture")`.
    Spec.assert_true ARGV.length >= 3
    Spec.assert_equal "--smoke", ARGV[0]
    Spec.assert_equal "test_wasi", ARGV[1]
  end

  Spec.assert "ARGV.first is not the program name" do
    # We skip argv[0] (program name) like CRuby does.
    Spec.assert_false ARGV.first == "mruby-js-bridge"
  end
end

Spec.describe "WASI: filesystem → File.read / File.open" do
  Spec.assert "File.read returns the bytes the host injected via fs.set" do
    # The runner pre-populates these; see wasm_spec/runner.mjs.
    content = File.read("/spec_fixture.txt")
    Spec.assert_equal "spec\nfixture\nlines\n", content
  end

  Spec.assert "File.open with a block yields and closes" do
    File.open("/spec_fixture.txt", "r") do |f|
      Spec.assert_equal "spec", f.gets.chomp
      Spec.assert_equal "fixture", f.gets.chomp
    end
  end

  Spec.assert "File.read on missing path raises" do
    Spec.assert_raises(RuntimeError) { File.read("/no_such_file") }
  end

  Spec.assert "binary fixture round-trips" do
    bytes = File.read("/spec_binary.dat")
    Spec.assert_equal 4, bytes.bytesize
    # 0xDE 0xAD 0xBE 0xEF
    Spec.assert_equal 0xDE, bytes.bytes[0]
    Spec.assert_equal 0xEF, bytes.bytes[3]
  end
end
