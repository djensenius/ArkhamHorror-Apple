import Foundation

/// A single cached asset's payload and explicit metadata, held together so
/// memory and disk layers agree on what "an entry" is.
struct CachedAsset: Sendable, Equatable {
    let payload: Data
    var metadata: AssetCacheMetadata

    /// The durable, cross-instance/cross-process clear epoch (see
    /// `AssetCacheService+Epoch.swift`'s ``AssetCacheService/CacheToken/durableClearEpoch``)
    /// observed at the moment this exact entry was published or
    /// successfully revalidated. Plain in-memory bookkeeping only —
    /// `metadata` is this struct's only `Codable`/persisted member, so
    /// this field has no on-disk schema of its own and is never written
    /// to or read from a disk-cache sidecar; a disk-read reconstruction
    /// (``AssetDiskCache/get(_:)``) always leaves it `nil`, since a
    /// disk-only hit is never independently trusted for memory-serving
    /// without first passing back through a fresh publish/touch, which
    /// alone stamps a real value here.
    ///
    /// Never trusted alone — every memory hit compares this stored value
    /// against a *freshly re-read* current epoch (see
    /// `AssetCacheService.memoryEntryStillCurrent(_:)`) immediately before
    /// serving the entry. This closes a gap the snapshot-then-recheck
    /// pattern used elsewhere in ``AssetCacheService`` cannot: a
    /// cross-instance/cross-process clear that already completed
    /// *before* a serving call even began is invisible to a snapshot
    /// taken (and re-checked) entirely after that clear, since both reads
    /// trivially agree with each other despite the entry itself having
    /// been published under a now-superseded epoch. Stamping the epoch
    /// directly onto the entry at publish time, and comparing it fresh on
    /// every subsequent hit, closes that window regardless of how long
    /// the entry has sat in memory since.
    var durableClearEpoch: Int?

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

    init(payload: Data, metadata: AssetCacheMetadata, durableClearEpoch: Int? = nil) {
        self.payload = payload
        self.metadata = metadata
        self.durableClearEpoch = durableClearEpoch
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

    /// The single most-recently-*applied* token per key, and the
    /// generation this actor currently accepts writes under — this
    /// actor's own independent half of the compare-and-swap described in
    /// `AssetCacheService+Epoch.swift`: `AssetCacheService` already
    /// re-checks authority on its own side of every actor hop, but that
    /// alone cannot protect against a race *inside* this exact call (a
    /// newer operation reaching this actor and being issued a fresher
    /// token while an older one is still suspended trying to reach it).
    /// Tracking token state here too closes that window without this
    /// actor needing to know anything about how `AssetCacheService`
    /// derives a token, only that a strictly greater one always wins.
    private var appliedToken: [AssetCacheKey: AssetCacheService.CacheToken] = [:]
    private var acceptedGeneration = 0

    /// Current total accounted bytes across every entry, maintained
    /// incrementally on every ``set(_:asset:token:)``/``remove(_:token:)``/
    /// ``removeAll()`` rather than re-summed from every entry on each
    /// call: recomputing this from scratch on every `set` (which used to
    /// happen via `evictIfNeeded()`) made every insert O(n) in the number
    /// of already-cached entries, even when nowhere near the configured
    /// budget. Each entry's own ``CachedAsset/accountedByteCount`` is
    /// itself already a one-time-computed value (see that property's doc
    /// comment), so this running total is exact by construction, not an
    /// approximation.
    private(set) var totalAccountedBytes = 0

    /// Test-only: when installed, awaited at the end of `get(_:)` — after
    /// the entry lookup and access-sequence bump, immediately before
    /// returning a captured hit — so a test can force a deterministic
    /// suspension point between capturing a hit's bytes and that hit
    /// actually reaching its caller, mirroring
    /// ``AssetDiskCache/testOnlyPauseBeforeReturningHit``.
    var testOnlyPauseBeforeReturningHit: (() async -> Void)?

    init(limits: AssetCacheLimits) {
        self.limits = limits
    }

    /// Test-only: installs ``testOnlyPauseBeforeReturningHit``. A plain
    /// actor-isolated method (rather than exposing the stored property for
    /// direct external assignment) so a test's call site reads as an
    /// ordinary, obviously-`await`-requiring actor call, matching
    /// ``AssetDiskCache/installTestOnlyPauseBeforeReturningHit(_:)``.
    func installTestOnlyPauseBeforeReturningHit(_ pause: @escaping () async -> Void) {
        testOnlyPauseBeforeReturningHit = pause
    }

    func get(_ key: AssetCacheKey) async -> CachedAsset? {
        guard var entry = entries[key] else { return nil }
        entry.metadata.accessSequence = accessSequence.allocate()
        entries[key] = entry
        if let pause = testOnlyPauseBeforeReturningHit {
            await pause()
        }
        return entry
    }

    /// Applies `asset` for `key`, gated by `token` when one is supplied:
    /// rejected (a silent no-op, returning `false`) if `token`'s
    /// generation is older than the most recent ``removeAll()``, or if a
    /// strictly-greater token has already been applied for this exact
    /// key — either case means a more-recently-issued operation has
    /// already superseded whichever caller is making this call, so its
    /// write must never land. A `nil` token always applies unconditionally
    /// (used only by tests exercising this actor in isolation).
    @discardableResult
    func set(
        _ key: AssetCacheKey,
        asset: CachedAsset,
        token: AssetCacheService.CacheToken? = nil
    ) -> Bool {
        if let token, !acceptToken(token, for: key) {
            return false
        }
        var stamped = asset
        stamped.metadata.accessSequence = accessSequence.allocate()
        if let previous = entries.updateValue(stamped, forKey: key) {
            totalAccountedBytes -= previous.accountedByteCount
        }
        totalAccountedBytes += stamped.accountedByteCount
        evictIfNeeded()
        return true
    }

    @discardableResult
    func remove(_ key: AssetCacheKey, token: AssetCacheService.CacheToken? = nil) -> Bool {
        if let token, !acceptToken(token, for: key) {
            return false
        }
        if let removed = entries.removeValue(forKey: key) {
            totalAccountedBytes -= removed.accountedByteCount
        }
        // See ``evictIfNeeded()``'s matching comment: an evicted/removed
        // key's applied-token bookkeeping must not outlive the entry it
        // was recorded for, or this dictionary grows without bound across
        // a high-cardinality (self-hosted/homebrew, effectively
        // attacker-controlled) key space even as entries themselves are
        // properly bounded by eviction.
        appliedToken[key] = nil
        return true
    }

    /// Removes `key`'s entry only if `token` is *exactly* the applied
    /// token currently recorded for it. Unlike ``remove(_:token:)``'s
    /// "reject if a newer token already applied" compare-and-swap
    /// semantics, this treats "some other token (older *or* newer) is
    /// currently applied" as "nothing to retract" rather than a failure —
    /// the caller already knows, from its own outer authority check, that
    /// `token` itself has already lost authority; it is asking this actor
    /// to undo specifically the mutation *it* performed under `token`, if
    /// that mutation is still the one resident. Used by
    /// ``AssetCacheService/publish(_:asset:token:)``/
    /// ``AssetCacheService/touch(_:asset:token:)`` to retract a memory
    /// write that landed successfully (this actor's own
    /// ``set(_:asset:token:)`` CAS passed) but was only *afterward* -- once
    /// that call's suspension returned control to ``AssetCacheService`` --
    /// discovered to already have been superseded by a more-recently
    /// -issued operation (or a cache-wide ``AssetCacheService/evictAll()``)
    /// for the same key, closing the exact window `publish`/`touch`
    /// previously only *detected* (returning ``AssetCacheService/MutationOutcome/stale``)
    /// without ever reverting the mutation that had already landed.
    func removeIfApplied(_ key: AssetCacheKey, token: AssetCacheService.CacheToken) {
        guard appliedToken[key] == token else { return }
        if let removed = entries.removeValue(forKey: key) {
            totalAccountedBytes -= removed.accountedByteCount
        }
        appliedToken[key] = nil
    }

    func removeAll() {
        entries.removeAll()
        totalAccountedBytes = 0
        appliedToken.removeAll()
        acceptedGeneration += 1
    }

    /// The compare half of this actor's own token CAS: accepts `token`
    /// only if its generation is not older than the generation this actor
    /// currently accepts writes under, and it is strictly newer than
    /// whatever token this actor last recorded as applied for `key` (a
    /// `nil` prior value always accepts). Records `token` as the new
    /// applied value on acceptance so a subsequent, older-issued token for
    /// the same key can never later overwrite it.
    private func acceptToken(
        _ token: AssetCacheService.CacheToken,
        for key: AssetCacheKey
    ) -> Bool {
        guard token.generation >= acceptedGeneration else { return false }
        if let applied = appliedToken[key], applied >= token {
            return false
        }
        appliedToken[key] = token
        return true
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
            // An evicted key's applied-token bookkeeping must not
            // outlive its entry -- see ``remove(_:token:)``'s matching
            // comment for why clearing this here cannot reintroduce a
            // stale-write race: the outer `AssetCacheService` authority
            // check already gates every `set(_:asset:token:)`/
            // `touch`/`remove` call *before* it ever reaches this actor,
            // so a genuinely stale (already-superseded) token can never
            // reach ``acceptToken(_:for:)`` in the first place regardless
            // of whether this dictionary still remembers an unrelated,
            // now-evicted prior entry's token.
            appliedToken[key] = nil
        }
    }
}
