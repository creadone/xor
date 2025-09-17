# frozen_string_literal: true

require 'set'

module Xor
  # Production-ready XOR filter with immutable snapshots and rebuild-on-write strategy.
  #
  # Notes:
  # - XOR filters are inherently static structures. To support add/remove, we keep
  #   an immutable base snapshot and small copy-on-write pending sets. When pending
  #   changes exceed a threshold, we rebuild the base snapshot from the full key set.
  # - Reads are lock-free (snapshot pointers + immutable sets). Writes are serialized
  #   under a mutex. This is safe under MRI and JRuby.
  class Filter
    DEFAULT_FP_BITS = 8
    DEFAULT_LOAD_FACTOR = 1.23
    DEFAULT_REBUILD_THRESHOLD_RATIO = 0.1
    MAGIC = "XORF".b
    FORMAT_VERSION = 1

    Snapshot = Struct.new(
      :seed,
      :fingerprint_bits,
      :fingerprint_mask,
      :table_size,
      :table,
      :keys, # Set of canonical keys used to build the table
      keyword_init: true
    )

    def initialize(capacity: 0, fingerprint_bits: DEFAULT_FP_BITS, load_factor: DEFAULT_LOAD_FACTOR, auto_rebuild: true)
      raise ArgumentError, "fingerprint_bits must be in 4..16" unless (4..16).include?(fingerprint_bits)
      @mutex = Mutex.new
      @auto_rebuild = auto_rebuild
      @rebuild_threshold_ratio = DEFAULT_REBUILD_THRESHOLD_RATIO
      @pending_adds = Set.new.freeze
      @pending_removes = Set.new.freeze

      base_keys = Set.new
      if capacity > 0
        @snapshot = build_snapshot_from_keys(base_keys, fingerprint_bits: fingerprint_bits, load_factor: load_factor)
      else
        # Empty snapshot
        @snapshot = Snapshot.new(
          seed: random_seed,
          fingerprint_bits: fingerprint_bits,
          fingerprint_mask: (1 << fingerprint_bits) - 1,
          table_size: 0,
          table: [].freeze,
          keys: base_keys.freeze
        )
      end
    end

    # Add element. Returns true if element was not present before (best-effort semantics).
    def add(value)
      key = canonical(value)
      @mutex.synchronize do
        # If key is scheduled for removal, cancel it
        if @pending_removes.include?(key) || @snapshot.keys.include?(key)
          new_rem = @pending_removes.dup
          new_rem.delete(key)
          @pending_removes = new_rem.freeze
          return false if @snapshot.keys.include?(key)
        end
        unless @pending_adds.include?(key) || @snapshot.keys.include?(key)
          new_add = @pending_adds.dup
          new_add.add(key)
          @pending_adds = new_add.freeze
          maybe_rebuild!
          true
        else
          false
        end
      end
    end

    # Remove element. Returns true if element was present (best-effort semantics).
    def remove(value)
      key = canonical(value)
      @mutex.synchronize do
        if @pending_adds.include?(key)
          new_add = @pending_adds.dup
          existed = new_add.delete?(key)
          @pending_adds = new_add.freeze
          return !!existed
        end
        if @snapshot.keys.include?(key) && !@pending_removes.include?(key)
          new_rem = @pending_removes.dup
          new_rem.add(key)
          @pending_removes = new_rem.freeze
          maybe_rebuild!
          true
        else
          false
        end
      end
    end

    # Membership query (approximate, with low false-positive rate).
    def include?(value)
      key = canonical(value)
      # Fast checks on pending sets first
      adds = @pending_adds
      return true if adds.include?(key)
      rems = @pending_removes
      return false if rems.include?(key)

      snap = @snapshot
      return false if snap.table_size.zero?
      f = fingerprint64(key, snap.seed) & snap.fingerprint_mask
      i0, i1, i2 = indices(key, snap.seed, snap.table_size)
      (snap.table[i0] ^ snap.table[i1] ^ snap.table[i2]) == f
    end

    # Approximate number of elements currently considered present
    def size
      snap = @snapshot
      snap.keys.size + @pending_adds.size - @pending_removes.size
    end

    # Force rebuild of the base snapshot applying all pendings
    def compact!
      @mutex.synchronize do
        rebuild!
      end
      true
    end

    # Bulk operations for efficiency under load
    def add_all(values)
      @mutex.synchronize do
        new_add = @pending_adds.dup
        new_rem = @pending_removes.dup
        values.each do |v|
          k = canonical(v)
          if new_rem.include?(k)
            new_rem.delete(k)
          elsif !new_add.include?(k) && !@snapshot.keys.include?(k)
            new_add.add(k)
          end
        end
        @pending_adds = new_add.freeze
        @pending_removes = new_rem.freeze
        maybe_rebuild!
      end
      true
    end

    def remove_all(values)
      @mutex.synchronize do
        new_add = @pending_adds.dup
        new_rem = @pending_removes.dup
        values.each do |v|
          k = canonical(v)
          if new_add.include?(k)
            new_add.delete(k)
          elsif @snapshot.keys.include?(k)
            new_rem.add(k)
          end
        end
        @pending_adds = new_add.freeze
        @pending_removes = new_rem.freeze
        maybe_rebuild!
      end
      true
    end

    # Save filter to a binary file
    def save(path)
      snap = @snapshot
      # Persist base snapshot and pending sets and flags
      File.open(path, "wb") do |io|
        io.write(MAGIC)
        io.write([FORMAT_VERSION].pack("L<"))
        io.write([snap.seed & 0xFFFFFFFFFFFFFFFF].pack("Q<"))
        io.write([snap.fingerprint_bits].pack("C"))
        io.write([snap.table_size].pack("Q<"))
        # Table entries as little-endian 2-byte values (fp_bits <= 16) for compactness
        # We store as 2 bytes each
        snap.table.each do |v|
          io.write([v & 0xFFFF].pack("S<"))
        end
        # Store keys (base) using Marshal for simplicity
        marshaled_keys = Marshal.dump(snap.keys.to_a)
        io.write([marshaled_keys.bytesize].pack("Q<"))
        io.write(marshaled_keys)
        # Store pending adds/removes
        pa = Marshal.dump(@pending_adds.to_a)
        pr = Marshal.dump(@pending_removes.to_a)
        io.write([pa.bytesize].pack("Q<"))
        io.write(pa)
        io.write([pr.bytesize].pack("Q<"))
        io.write(pr)
      end
      true
    end

    # Load filter from a binary file
    def self.load(path)
      File.open(path, "rb") do |io|
        magic = io.read(4)
        raise "Invalid file format" unless magic == MAGIC
        version = io.read(4).unpack1("L<")
        raise "Unsupported version #{version}" unless version == FORMAT_VERSION
        seed = io.read(8).unpack1("Q<")
        fp_bits = io.read(1).unpack1("C")
        table_size = io.read(8).unpack1("Q<")
        table = Array.new(table_size)
        table_size.times do |i|
          table[i] = io.read(2).unpack1("S<")
        end
        keys_len = io.read(8).unpack1("Q<")
        keys = Set.new(Marshal.load(io.read(keys_len)))
        pa_len = io.read(8).unpack1("Q<")
        pending_adds = Set.new(Marshal.load(io.read(pa_len))).freeze
        pr_len = io.read(8).unpack1("Q<")
        pending_removes = Set.new(Marshal.load(io.read(pr_len))).freeze

        filter = new(capacity: 0, fingerprint_bits: fp_bits)
        filter.instance_variable_set(:@snapshot, Snapshot.new(
          seed: seed,
          fingerprint_bits: fp_bits,
          fingerprint_mask: (1 << fp_bits) - 1,
          table_size: table_size,
          table: table.freeze,
          keys: keys.freeze
        ))
        filter.instance_variable_set(:@pending_adds, pending_adds)
        filter.instance_variable_set(:@pending_removes, pending_removes)
        filter
      end
    end

    private

    def maybe_rebuild!
      return unless @auto_rebuild
      snap = @snapshot
      base = snap.keys.size
      pend = @pending_adds.size + @pending_removes.size
      threshold = [1000, (base * @rebuild_threshold_ratio).ceil].max
      rebuild! if pend >= threshold
    end

    def rebuild!
      # Compose new key set
      new_keys = @snapshot.keys.dup
      @pending_adds.each { |k| new_keys.add(k) }
      @pending_removes.each { |k| new_keys.delete(k) }
      @pending_adds = Set.new.freeze
      @pending_removes = Set.new.freeze
      @snapshot = build_snapshot_from_keys(new_keys)
    end

    def build_snapshot_from_keys(keys, fingerprint_bits: nil, load_factor: DEFAULT_LOAD_FACTOR)
      fingerprint_bits ||= @snapshot&.fingerprint_bits || DEFAULT_FP_BITS
      fingerprint_mask = (1 << fingerprint_bits) - 1
      n = keys.size
      table_size = [1, (n * load_factor).ceil].max
      seed = random_seed
      # Retry build up to a few times with different seeds
      10.times do
        ok, table, used_seed = try_build(keys, table_size, fingerprint_bits, fingerprint_mask, seed)
        if ok
          return Snapshot.new(
            seed: used_seed,
            fingerprint_bits: fingerprint_bits,
            fingerprint_mask: fingerprint_mask,
            table_size: table_size,
            table: table.freeze,
            keys: keys.freeze
          )
        end
        seed = random_seed
      end
      # If still not ok, grow and try again
      loop do
        table_size = (table_size * 1.1).ceil
        10.times do
          ok, table, used_seed = try_build(keys, table_size, fingerprint_bits, fingerprint_mask, random_seed)
          if ok
            return Snapshot.new(
              seed: used_seed,
              fingerprint_bits: fingerprint_bits,
              fingerprint_mask: fingerprint_mask,
              table_size: table_size,
              table: table.freeze,
              keys: keys.freeze
            )
          end
        end
      end
    end

    # Try to build XOR filter via peeling. Returns [ok, table, seed]
    def try_build(keys, m, fp_bits, fp_mask, seed)
      return [true, Array.new(m, 0), seed] if keys.empty?

      # Edges: for each key store its three vertices
      edges = []
      degree = Array.new(m, 0)
      keys.each do |k|
        i0, i1, i2 = indices(k, seed, m)
        edges << [i0, i1, i2, k]
        degree[i0] += 1
        degree[i1] += 1
        degree[i2] += 1
      end

      # For each vertex, track incident edges indices via XOR trick
      # Maintain count and xor of edge ids to find the remaining incident edge when degree==1
      v_count = degree.dup
      v_xor = Array.new(m, 0)
      edges.each_with_index do |(a,b,c,_k), idx|
        v_xor[a] ^= idx
        v_xor[b] ^= idx
        v_xor[c] ^= idx
      end

      queue = []
      (0...m).each { |v| queue << v if v_count[v] == 1 }

      order = [] # will store [edge_idx, picked_vertex]
      processed_edges = 0
      while (v = queue.pop)
        next unless v_count[v] == 1
        e_idx = v_xor[v]
        a, b, c, _k = edges[e_idx]
        picked_vertex = v
        order << [e_idx, picked_vertex]
        processed_edges += 1
        # Decrement degrees and update xor trackers
        [a, b, c].each do |u|
          next if u == v && v_count[u] == 1
          if v_count[u] > 0
            v_count[u] -= 1
            v_xor[u] ^= e_idx
            queue << u if v_count[u] == 1
          end
        end
        v_count[v] = 0
      end

      return [false, nil, seed] unless processed_edges == edges.size

      table = Array.new(m, 0)
      # Assign fingerprints in reverse order
      order.reverse_each do |e_idx, picked|
        a, b, c, k = edges[e_idx]
        f = fingerprint64(k, seed) & fp_mask
        i0, i1 = (picked == a) ? [b, c] : (picked == b ? [a, c] : [a, b])
        table[picked] = f ^ table[i0] ^ table[i1]
      end

      [true, table, seed]
    end

    # Compute 64-bit fingerprint for a key
    def fingerprint64(key, seed)
      h = splitmix64(key_hash64(key) ^ seed)
      # Use upper 32 bits for more dispersion, then fold
      ((h >> 32) ^ (h & 0xFFFFFFFF)) & 0xFFFFFFFF
    end

    # Get three indices for the key within table of size m
    def indices(key, seed, m)
      h = splitmix64(key_hash64(key) ^ seed)
      a = (h & 0xFFFFFFFF)
      b = ((h >> 21) & 0xFFFFFFFF)
      c = ((h >> 42) & 0xFFFFFFFF)
      i0 = a % m
      i1 = (b ^ a) % m
      i2 = (c ^ a) % m
      [i0, i1, i2]
    end

    # Stable canonicalization of values to strings for consistent hashing
    def canonical(value)
      case value
      when String
        value.b
      else
        value.to_s.b
      end
    end

    def key_hash64(key)
      # FNV-1a 64-bit
      hash = 0xcbf29ce484222325
      key.each_byte do |byte|
        hash ^= byte
        hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
      end
      hash
    end

    def splitmix64(x)
      z = (x + 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF
      z ^= (z >> 30)
      z = (z * 0xBF58476D1CE4E5B9) & 0xFFFFFFFFFFFFFFFF
      z ^= (z >> 27)
      z = (z * 0x94D049BB133111EB) & 0xFFFFFFFFFFFFFFFF
      z ^= (z >> 31)
      z & 0xFFFFFFFFFFFFFFFF
    end

    def random_seed
      # Use Ruby's Random for 64-bit seed
      (Random.new.rand(1<<30) << 34) ^ Random.new.rand(1<<34)
    end
  end
end
