import Foundation

/// A single cached asset's payload and explicit metadata, held together so
/// memory and disk layers agree on what "an entry" is.
struct CachedAsset: Sendable, Equatable {
    let payload: Data
    var metadata: AssetCacheMetadata

    /// This entry's actual payload byte count plus
    /// ``AssetCacheMetadata/metadataOverheadBytes``, computed once here at
    /// construction rather than re-derived on every accounting pass.
    ///
    /// Deliberately measures `payload.count` directly — the one value this
    /// struct can independently verify — rather than trusting
    /// ``AssetCacheMetadata/encodedByteCount``, which is merely what the
    /// metadata *declares* the payload size to be. If that declared value
    /// ever diverged from the real payload (a future bug, tampered/corrupt
    /// metadata reused in-memory, or a call site accidentally passing
    /// mismatched values), billing off the declared count alone could
    /// under- or over-bill this entry and undermine the configured memory
    /// budget; billing off the payload actually held here cannot diverge
    /// from what is actually resident in memory.
    ///
    /// ``AssetCacheMetadata/metadataOverheadBytes`` measures a real
    /// serialized JSON byte count (see that property's doc comment), so
    /// re-deriving it on every ``AssetMemoryCache`` accounting pass — which
    /// runs on *every* `set(_:asset:)` call via `evictIfNeeded()`, not only
    /// when a quota breach is actually near — would make every insert
    /// O(n) in the number of already-cached entries, with one JSON encode
    /// per entry. Caching it here avoids re-encoding `metadata` to JSON on
    /// every ``AssetMemoryCache`` accounting pass — i.e. it keeps that one
    /// JSON encode a one-time cost per entry rather than paying it again on
    /// every subsequent `set`/`get`/eviction accounting walk over every
    /// already-cached entry. `metadata`'s
    /// `accessSequence` still mutates on every read (see `get(_:)` below),
    /// but that does not invalidate this cached value: ``AssetAccessSequence``
    /// always encodes to the same fixed-width string regardless of the
    /// specific value, so the entry's true serialized size never actually
    /// changes after construction.
    let accountedByteCount: Int

    init(payload: Data, metadata: AssetCacheMetadata) {
        self.payload = payload
        self.metadata = metadata
        accountedByteCount = payload.count + metadata.metadataOverheadBytes
    }
}

/// An actor-isolated, in-memory LRU cache bounded by
/// ``AssetCacheLimits/memoryBudgetBytes``.
///
/// Explicit ``AssetCacheMetadata/accessSequence`` (updated on every read)
/// drives eviction order — never insertion order alone and never anything
/// derived from the filesystem. Eviction order is derived directly from
/// this field only when a quota breach actually requires evicting (an
/// infrequent operation relative to `get`/`set`), rather than maintaining a
/// separately-tracked access-order list that would need an O(n) update on
/// every single read or write to keep in sync.
actor AssetMemoryCache {
    private var entries: [AssetCacheKey: CachedAsset] = [:]
    private let limits: AssetCacheLimits

    /// This actor's own private LRU sequence, independent of whatever
    /// value ``AssetDiskCache`` may have stamped into the same metadata
    /// field: the memory cache never persists across a restart, so it has
    /// no recovery concern and always starts from `0` for a fresh process.
    private var accessSequence = AssetAccessSequenceAllocator()

    /// Current total accounted bytes across every entry, maintained
    /// incrementally on every ``set(_:asset:)``/``remove(_:)``/
    /// ``removeAll()`` rather than re-summed from every entry on each
    /// call: recomputing this from scratch on every `set` (which used to
    /// happen via `evictIfNeeded()`) made every insert O(n) in the number
    /// of already-cached entries, even when nowhere near the configured
    /// budget. Each entry's own ``CachedAsset/accountedByteCount`` is
    /// itself already a one-time-computed value (see that property's doc
    /// comment), so this running total is exact by construction, not an
    /// approximation.
    private(set) var totalAccountedBytes = 0

    init(limits: AssetCacheLimits) {
        self.limits = limits
    }

    func get(_ key: AssetCacheKey) -> CachedAsset? {
        guard var entry = entries[key] else { return nil }
        entry.metadata.accessSequence = accessSequence.allocate()
        entries[key] = entry
        return entry
    }

    func set(_ key: AssetCacheKey, asset: CachedAsset) {
        var stamped = asset
        stamped.metadata.accessSequence = accessSequence.allocate()
        if let previous = entries.updateValue(stamped, forKey: key) {
            totalAccountedBytes -= previous.accountedByteCount
        }
        totalAccountedBytes += stamped.accountedByteCount
        evictIfNeeded()
    }

    func remove(_ key: AssetCacheKey) {
        if let removed = entries.removeValue(forKey: key) {
            totalAccountedBytes -= removed.accountedByteCount
        }
    }

    func removeAll() {
        entries.removeAll()
        totalAccountedBytes = 0
    }

    private func evictIfNeeded() {
        guard totalAccountedBytes > limits.highWaterMarkMemoryBytes else { return }
        let oldestFirst = entries.sorted { lhs, rhs in
            lhs.value.metadata.accessSequence != rhs.value.metadata.accessSequence
                ? lhs.value.metadata.accessSequence < rhs.value.metadata.accessSequence
                : lhs.key.digestHex < rhs.key.digestHex
        }
        for (key, asset) in oldestFirst {
            guard totalAccountedBytes > limits.lowWaterMarkMemoryBytes else { break }
            entries.removeValue(forKey: key)
            totalAccountedBytes -= asset.accountedByteCount
        }
    }
}
