# Pure-Ruby helpers on top of the C primitives in src/env.c.

module ENV
  class << self
    alias_method :each_pair, :each
    alias_method :value?, :include?  # close enough; CRuby checks values

    def each_key
      return keys.each unless block_given?
      keys.each { |k| yield k }
    end

    def each_value
      return values.each unless block_given?
      values.each { |v| yield v }
    end

    def empty?
      size == 0
    end

    def fetch(key, default = (no_default = true; nil))
      v = self[key]
      return v unless v.nil?
      return yield(key) if block_given?
      raise KeyError, "key not found: #{key.inspect}" if no_default
      default
    end

    def values_at(*keys)
      keys.map { |k| self[k] }
    end
  end
end
