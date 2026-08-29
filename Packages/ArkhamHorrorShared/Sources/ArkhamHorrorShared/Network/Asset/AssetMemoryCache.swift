import Foundation

/// A single cached asset's payload and explicit metadata, held together so
/// memory and disk layers agree on what "an entry" is.
struct CachedAsset: Sendable, Equatable {
    let payload: Data
    var metadata: AssetCacheMetadata
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

    /// Current total accounted bytes (payload + metadata overhead) across
    /// every entry.
    var totalAccountedBytes: Int {
        entries.values.reduce(0) { $0 + $1.metadata.accountedByteCount }
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
            total -= asset.metadata.accountedByteCount
        }
    }
}
