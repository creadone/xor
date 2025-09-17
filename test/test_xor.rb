# frozen_string_literal: true

require "test_helper"

class TestXor < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Xor::VERSION
  end

  def test_add_and_include
    f = Xor::Filter.new(capacity: 0)
    refute f.include?("a")
    f.add("a")
    assert f.include?("a")
  end

  def test_add_and_remove
    f = Xor::Filter.new(capacity: 0)
    f.add("a")
    assert f.include?("a")
    f.remove("a")
    refute f.include?("a")
  end

  def test_persistence_roundtrip
    f = Xor::Filter.new(capacity: 0)
    %w[a b c].each { |k| f.add(k) }
    path = File.join(Dir.mktmpdir, "xor.bin")
    begin
      f.save(path)
      loaded = Xor::Filter.load(path)
      %w[a b c].each { |k| assert loaded.include?(k) }
      refute loaded.include?("z")
    ensure
      File.unlink(path) if File.exist?(path)
    end
  end

  def test_bulk
    f = Xor::Filter.new(capacity: 0)
    f.add_all(%w[a b c d])
    %w[a b c d].each { |k| assert f.include?(k) }
    f.remove_all(%w[b d])
    assert f.include?("a")
    refute f.include?("b")
    assert f.include?("c")
    refute f.include?("d")
  end

  def test_compact
    f = Xor::Filter.new(capacity: 0, auto_rebuild: false)
    f.add_all(%w[a b c])
    # Without auto rebuild, include? relies on pendings
    %w[a b c].each { |k| assert f.include?(k) }
    f.compact!
    %w[a b c].each { |k| assert f.include?(k) }
  end
end
