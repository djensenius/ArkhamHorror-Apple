import Foundation

/// A single cached asset's payload and explicit metadata, held together so
/// memory and disk layers agree on what "an entry" is.
struct CachedAsset: Sendable, Equatable {
    let payload: Data
    var metadata: AssetCacheMetadata

    /// ``AssetCacheMetadata/accountedByteCount``, computed once here at
    /// construction rather than re-derived on every accounting pass.
    ///
    /// ``AssetCacheMetadata/accountedByteCount`` measures a real serialized
    /// JSON byte count (see that property's doc comment), so re-deriving it
    /// on every ``AssetMemoryCache`` accounting pass — which runs on
    /// *every* `set(_:asset:)` call via `evictIfNeeded()`, not only when a
    /// quota breach is actually near — would make every insert O(n) in the
    /// number of already-cached entries, with one JSON encode per entry.
    /// Caching it here avoids re-encoding `metadata` to JSON on every
    /// ``AssetMemoryCache`` accounting pass — i.e. it keeps that one JSON
    /// encode a one-time cost per entry rather than paying it again on
    /// every subsequent `set`/`get`/eviction accounting walk over every
    /// already-cached entry. `metadata`'s
    /// `lastAccessedAt` still mutates on every read (see `get(_:)` below),
    /// but that does not invalidate this cached value: `JSONEncoder`'s
    /// `.iso8601` date strategy always encodes to the same string width
    /// regardless of the specific instant, so the entry's true serialized
    /// size never actually changes after construction.
    let accountedByteCount: Int

    init(payload: Data, metadata: AssetCacheMetadata) {
        self.payload = payload
        self.metadata = metadata
        accountedByteCount = metadata.accountedByteCount
    }
}

/// An actor-isolated, in-memory LRU cache bounded by
/// ``AssetCacheLimits/memoryBudgetBytes``.
///
/// Explicit ``AssetCacheMetadata/lastAccessedAt`` (updated on every read)
/// drives eviction order — never insertion order alone and never anything
/// derived from the filesystem. Eviction order is derived directly from
/// this field only when a quota breach actually requires evicting (an
/// infrequent operation relative to `get`/`set`), rather than maintaining a
/// separately-tracked access-order list that would need an O(n) update on
/// every single read or write to keep in sync.
actor AssetMemoryCache {
    private var entries: [AssetCacheKey: CachedAsset] = [:]
    private let limits: AssetCacheLimits

    init(limits: AssetCacheLimits) {
        self.limits = limits
    }

    func get(_ key: AssetCacheKey) -> CachedAsset? {
        guard var entry = entries[key] else { return nil }
        entry.metadata.lastAccessedAt = Date()
        entries[key] = entry
        return entry
    }

    func set(_ key: AssetCacheKey, asset: CachedAsset) {
        entries[key] = asset
        evictIfNeeded()
    }

    func remove(_ key: AssetCacheKey) {
        entries.removeValue(forKey: key)
    }

    func removeAll() {
        entries.removeAll()
    }

    /// Current total accounted bytes across every entry: each entry's
    /// payload byte count plus its metadata sidecar's actual serialized
    /// JSON size (see ``CachedAsset/accountedByteCount``) — not a fixed
    /// metadata-overhead estimate.
    var totalAccountedBytes: Int {
        entries.values.reduce(0) { $0 + $1.accountedByteCount }
    }

    private func evictIfNeeded() {
        var total = totalAccountedBytes
        guard total > limits.highWaterMarkMemoryBytes else { return }
        let oldestFirst = entries.sorted {
            $0.value.metadata.lastAccessedAt < $1.value.metadata.lastAccessedAt
        }
        for (key, asset) in oldestFirst {
            guard total > limits.lowWaterMarkMemoryBytes else { break }
            entries.removeValue(forKey: key)
            total -= asset.accountedByteCount
        }
    }
}
