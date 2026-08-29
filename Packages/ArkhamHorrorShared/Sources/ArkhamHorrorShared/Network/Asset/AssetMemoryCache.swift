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
/// derived from the filesystem.
actor AssetMemoryCache {
    private var entries: [AssetCacheKey: CachedAsset] = [:]
    /// Access order, most-recently-used last. Kept separately from the
    /// dictionary so eviction can walk oldest-first without re-sorting.
    private var accessOrder: [AssetCacheKey] = []
    private let limits: AssetCacheLimits

    init(limits: AssetCacheLimits) {
        self.limits = limits
    }

    func get(_ key: AssetCacheKey) -> CachedAsset? {
        guard var entry = entries[key] else { return nil }
        entry.metadata.lastAccessedAt = Date()
        entries[key] = entry
        touch(key)
        return entry
    }

    func set(_ key: AssetCacheKey, asset: CachedAsset) {
        entries[key] = asset
        touch(key)
        evictIfNeeded()
    }

    func remove(_ key: AssetCacheKey) {
        entries.removeValue(forKey: key)
        accessOrder.removeAll { $0 == key }
    }

    func removeAll() {
        entries.removeAll()
        accessOrder.removeAll()
    }

    /// Current total accounted bytes (payload + metadata overhead) across
    /// every entry.
    var totalAccountedBytes: Int {
        entries.values.reduce(0) { $0 + $1.metadata.accountedByteCount }
    }

    private func touch(_ key: AssetCacheKey) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func evictIfNeeded() {
        guard totalAccountedBytes > limits.highWaterMarkMemoryBytes else { return }
        while totalAccountedBytes > limits.lowWaterMarkMemoryBytes, let oldest = accessOrder.first {
            entries.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }
    }
}
