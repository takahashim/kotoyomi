# Minimal spec framework for mruby-wasm-js tests. assert / assert_equal /
# assert_raises in the mruby-test idiom, but lightweight (no rake-test
# integration). Each test file calls Spec.describe / Spec.assert; the
# Node runner triggers Spec.summary at the end which prints a per-group
# table and exposes pass/fail to JS via JS.global[:__test_failed__].

module Spec
  @groups = []
  @counts = { tests: 0, asserts: 0, failures: 0 }
  # Per-Fiber active group, so test files that yield (await tests) don't
  # have their results leak into another file's group when control
  # alternates between fibers via Promise resumes.
  @fiber_groups = {}

  class << self
    def describe(name)
      group = [name, []]
      @groups << group
      @fiber_groups[::Fiber.current] = group
      begin
        yield
      ensure
        @fiber_groups.delete(::Fiber.current)
      end
    end

    # Wraps a test: runs the block, records result. Any error from the
    # block (including assertion failures) is caught.
    def assert(message)
      @counts[:tests] += 1
      yield
      record(:pass, message)
    rescue => err
      @counts[:failures] += 1
      record(:fail, message, err)
    end

    def assert_equal(expected, actual, msg = nil)
      @counts[:asserts] += 1
      return if expected == actual
      raise "expected #{expected.inspect}, got #{actual.inspect}#{msg ? " (#{msg})" : ""}"
    end

    def assert_true(value, msg = nil)
      @counts[:asserts] += 1
      return if value
      raise "expected truthy#{msg ? " (#{msg})" : ""}, got #{value.inspect}"
    end

    def assert_false(value, msg = nil)
      @counts[:asserts] += 1
      return if !value
      raise "expected falsy, got #{value.inspect}"
    end

    # Returns the raised exception so it can be inspected further.
    def assert_raises(klass)
      @counts[:asserts] += 1
      err = nil
      begin
        yield
      rescue Exception => e # rubocop:disable Lint/RescueException
        err = e
      end
      raise "expected #{klass}, but nothing raised" if err.nil?
      raise "expected #{klass}, got #{err.class}: #{err.message}" unless err.is_a?(klass)
      err
    end

    def summary
      puts ""
      @groups.each do |name, results|
        pass = results.count { |r| r[0] == :pass }
        total = results.length
        status = total == pass ? "OK  " : "FAIL"
        puts "[#{status}] #{name}: #{pass}/#{total}"
        results.each do |r|
          if r[0] == :fail
            puts "  - #{r[1]}"
            puts "    #{r[2].class}: #{r[2].message}"
          end
        end
      end
      puts ""
      puts "#{@counts[:tests] - @counts[:failures]}/#{@counts[:tests]} tests pass (#{@counts[:asserts]} assertions)"
      JS.global[:__test_failed__] = @counts[:failures] > 0
    end

    private

    def record(*entry)
      group = @fiber_groups[::Fiber.current]
      group[1] << entry if group
    end
  end
end
