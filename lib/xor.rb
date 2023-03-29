# frozen_string_literal: true

module Xor
  class Filter
    def initialize(size)
      @size = size
      @hashes = Array.new(size, 0)
    end

    def add(value)
      hash1, hash2 = hash(value)
      @hashes[hash1 % @size] ^= hash2
    end

    def include?(value)
      hash1, hash2 = hash(value)
      (@hashes[hash1 % @size] ^ hash2).zero?
    end

    private

    def hash(value)
      hash1 = value.hash
      hash2 = hash1 >> 16
      [hash1, hash2]
    end
  end
end
