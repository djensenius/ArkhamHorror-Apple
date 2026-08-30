import CoreGraphics
import Foundation

/// Actor-isolated orchestration for resolving an ``AssetKey`` to validated
/// image bytes, backed by an in-memory cache, an on-disk cache, and a
/// network transport.
///
/// Responsibilities beyond the individual layers:
/// - Walks ``AssetLocator``'s candidate list, advancing to the next
///   candidate only on an exact 404 (``AssetHTTPResult/notFound``); every
///   other failure (transport, redirect, unexpected status, content
///   validation) is terminal for the whole request.
/// - Coalesces concurrent requests for the same resolved cache key onto a
///   single in-flight fetch. A waiter that cancels only decrements its own
///   share of that work; the underlying fetch is cancelled only once the
///   last waiter has left, and a cancelled fetch never publishes a partial
///   cache entry.
/// - Revalidates conditionally (`ETag`/`Last-Modified`) against the exact
///   URL a cached payload came from; a 304 is only ever treated as success
///   when paired with a currently valid cached payload.
actor AssetCacheService {
    /// Shorthand for the continuation type shared by both the coalesced
    /// network-fetch and coalesced-revalidation waiter dictionaries, kept
    /// as a single typealias (rather than repeating the full generic
    /// spelling at every use site) purely so those call sites stay under
    /// this package's line-length limit.
    typealias AssetContinuation = CheckedContinuation<Result<CachedAsset, Error>, Never>

    let memoryCache: AssetMemoryCache
    let diskCache: AssetDiskCache
    let transport: any AssetTransport
    let digest: any LocalizedDigestLookup
    let limits: AssetCacheLimits

    /// Not `private`: also mutated by `AssetCacheService+Eviction.swift`'s
    /// ``evictAll()``, which must resume and clear every in-flight
    /// fetch's waiters before this actor's own completion watchers would
    /// otherwise find their entry already gone.
    var inFlight: [AssetCacheKey: InFlightFetch] = [:]

    /// Per-key issuance-ordered authority state and the shared global
    /// generation, together forming the single authority every
    /// cache-mutating operation (a normal fetch's publish, a
    /// revalidation's 404/304/200 outcome, or ``evictAll()``) must check
    /// itself against immediately before ever touching memory/disk state
    /// — see `AssetCacheService+Epoch.swift` for the full ``CacheToken``
    /// issuance/CAS contract.
    var keyIssuance: [AssetCacheKey: Int] = [:]
    var keyLatestToken: [AssetCacheKey: CacheToken] = [:]
    var globalGeneration = 0
    var inFlightRevalidation: [RevalidationSlot: RevalidationFetch] = [:]

    /// Bumped for exactly `key` every time ``invalidate(_:token:)``
    /// actually proceeds to remove it (a definitive 404, a failed
    /// re-validation quarantine, or a URL-mismatch quarantine) — a
    /// narrower, more precise question than "has *any* operation been
    /// issued for this key since", which ``keyLatestToken`` alone answers
    /// and which a perfectly legitimate, coalescable sibling
    /// ``asset(for:)``/``revalidate(for:)`` call for the very same key
    /// would also (harmlessly) advance. Combined with `globalGeneration`
    /// (bumped by ``evictAll()``, which affects every key at once without
    /// calling ``invalidate(_:token:)`` for each one individually), this
    /// is what ``revalidate(for:)``'s memory-hit branch checks a cached
    /// snapshot against before ever letting it mint a fresh authority
    /// token: see ``snapshotClearState(for:)``/``clearStateUnchanged(since:for:)``
    /// in `AssetCacheService+Epoch.swift`, and that function's doc
    /// comment for why the coarser `keyLatestToken`-based check is wrong
    /// for this specific purpose.
    var keyClearGeneration: [AssetCacheKey: Int] = [:]

    /// Keys whose disk entry this actor knows it *intended* to invalidate
    /// (a definitive 404, a failed re-validation quarantine, or
    /// ``evictAll()``) but where the underlying physical deletion could
    /// not be confirmed to have fully succeeded. ``AssetDiskCache``
    /// surfaces a deletion failure as a typed error rather than silently
    /// swallowing it (see its doc comment); this set is what keeps that
    /// typed failure from being a no-op here: a tombstoned key is treated
    /// as absent from disk regardless of what a subsequent
    /// ``AssetDiskCache/get(_:)`` might still be able to read back, so a
    /// deletion the filesystem could not physically complete can never
    /// let a stale/invalidated body be served again. Cleared only when a
    /// fresh, successful publish for that exact key later supersedes
    /// whatever the tombstone was protecting against.
    var tombstonedKeys: Set<AssetCacheKey> = []

    /// The most recent disk-cache persistence failure from ``publish``, if
    /// any, retained so a best-effort (non-fatal) disk write failure is
    /// still auditable rather than silently swallowed — a resolved asset
    /// remains usable in-memory for the current process even when the
    /// on-disk cache could not be written (e.g. an unwritable or full
    /// cache directory), so this is deliberately not thrown back to the
    /// caller that just successfully resolved the asset. Not
    /// `private(set)`: also written by `AssetCacheService+Eviction.swift`'s
    /// ``evictAll()`` on a partial disk-clear failure.
    var lastDiskPersistenceFailure: AssetError?

    init(
        memoryCache: AssetMemoryCache,
        diskCache: AssetDiskCache,
        transport: any AssetTransport = URLSessionAssetTransport(),
        digest: any LocalizedDigestLookup = BundledLocalizedDigestProvider.shared,
        limits: AssetCacheLimits = .production
    ) {
        self.memoryCache = memoryCache
        self.diskCache = diskCache
        self.transport = transport
        self.digest = digest
        self.limits = limits
    }

    /// Resolves `key` to a validated cached asset, serving from memory or
    /// disk when a valid entry already exists and otherwise performing (or
    /// joining an already in-flight) network fetch.
    func asset(for key: AssetKey) async throws -> CachedAsset {
        let candidates = try resolvedCandidates(for: key)
        let cacheKey = AssetCacheKey(for: key, candidates: candidates)

        // Snapshotted *before* the memory-cache read itself, mirroring the
        // disk-hit snapshot immediately below: `memoryCache.get` suspends
        // (a genuine hop to a different actor), during which a
        // more-recently-issued operation for this exact key — or a
        // cache-wide `evictAll()` — can become authoritative on *this*
        // actor without that having any effect on `memoryCache`'s own
        // already-in-flight `get` call. Without this check, such a race
        // could still hand back an entry this actor's own bookkeeping
        // already considers superseded, purely because of memory-cache
        // actor-hop timing luck.
        let memorySnapshot = snapshotAuthority(for: cacheKey)
        let memoryHit = await memoryCache.get(cacheKey)
        if let cached = memoryHit, unchanged(since: memorySnapshot, for: cacheKey) {
            return cached
        }
        // A tombstoned key means this actor already intended to invalidate
        // its disk entry (a 404, a failed re-validation quarantine, or
        // `evictAll()`) but could not confirm the physical deletion fully
        // succeeded — never trust a disk read for it, regardless of what
        // bytes might still physically be present, until a fresh publish
        // clears the tombstone.
        if !tombstonedKeys.contains(cacheKey) {
            // Snapshotted *before* the disk read itself (not issued as a
            // token yet), so a subsequent mismatch can detect a more
            // -recently-issued operation for this exact key -- or
            // `evictAll()` -- that became authoritative while this disk
            // read was still in flight (the disk actor's own serialized
            // queue can run this `get` either before or after such an
            // operation's own disk-side effects, independent of the order
            // the two operations' tokens are issued in on *this* actor).
            // See ``snapshotAuthority(for:)``'s doc comment for why this
            // must not itself issue a token: a disk miss (or a hit that
            // loses this race) must never have consumed an issuance
            // number or superseded whatever fetch is legitimately already
            // in flight for this key, merely because a second,
            // ultimately-coalescing caller also passed through this same
            // code path.
            let snapshot = snapshotAuthority(for: cacheKey)
            let diskHit = await diskCache.get(cacheKey)
            if let cached = diskHit, unchanged(since: snapshot, for: cacheKey) {
                let token = issueToken(for: cacheKey)
                if let revalidated = try await revalidateDiskHit(
                    cached,
                    key: key,
                    cacheKey: cacheKey,
                    candidates: candidates,
                    token: token
                ) {
                    // `revalidateDiskHit` suspends (a full platform
                    // decode); re-check this key's authority immediately
                    // before caching its result back into memory *and*
                    // before ever returning it to this call's own caller —
                    // a `evictAll()` or a more-recently-issued operation
                    // for this exact key may already have concluded while
                    // this suspension was in progress, and handing back a
                    // value this actor's own bookkeeping already considers
                    // superseded would let a caller observe (and possibly
                    // display) content the cache layer itself no longer
                    // considers authoritative. `memoryCache.set`
                    // independently re-checks the same token itself (see
                    // its doc comment), so that call is deliberately
                    // defense-in-depth, not this check's only enforcement
                    // point — this outer check is what protects the
                    // *return value*, which `memoryCache.set`'s own
                    // internal check cannot do.
                    if isAuthoritative(token, for: cacheKey) {
                        await memoryCache.set(cacheKey, asset: revalidated, token: token)
                        return revalidated
                    }
                    // Falls through to a fresh network fetch below exactly
                    // like a genuine cache miss: this exact disk-hit read
                    // is no longer authoritative, so neither promoting it
                    // into memory nor returning it to this call's caller
                    // would be consistent with whatever operation
                    // superseded it.
                } else {
                    // The persisted entry failed re-validation against the
                    // *current* format/magic/dimension/limits/decode
                    // contract (see ``revalidateDiskHit``): it has already
                    // been quarantined (removed from disk), so fall
                    // through to a fresh network fetch exactly as if
                    // nothing had been cached at all, rather than
                    // surfacing the stale/invalid bytes or poisoning this
                    // call permanently.
                    // `CancellationError` is not caught here:
                    // `revalidateDiskHit` rethrows it rather than
                    // returning `nil`, propagating straight out instead of
                    // falling through.
                }
            }
            // Either a genuine disk miss, or a disk hit whose read raced
            // with a more authoritative concurrent operation for this
            // exact key and so cannot be trusted or promoted -- both fall
            // through identically to a fresh network fetch below, which
            // issues (or joins) its own currently-authoritative token.
        }
        return try await coalescedFetch(key: key, cacheKey: cacheKey, candidates: candidates)
    }

    /// Publishes a resolved asset into both cache layers, gated by
    /// `token` at every hop: immediately before the memory-cache write,
    /// again immediately before the disk-cache write (a disk write is a
    /// second, independent suspension after the first), and — beyond this
    /// actor's own re-checks — ``AssetMemoryCache/set(_:asset:token:)``
    /// and ``AssetDiskCache/set(_:payload:metadata:token:)`` each
    /// independently re-verify the same token themselves before mutating
    /// their own state, so a write that loses the race strictly *within*
    /// one of those actor calls (not merely between this actor's own
    /// checks) still cannot land. The disk write is deliberately
    /// best-effort (an in-memory-only asset is still usable for the
    /// remainder of the process), but that decision is centralized here
    /// in an explicit `do`/`catch` — rather than a bare `try?` — so a
    /// persistence failure is captured in ``lastDiskPersistenceFailure``
    /// for auditing/instrumentation instead of vanishing silently. A
    /// successful disk write always clears `cacheKey`'s tombstone (see
    /// ``tombstonedKeys``): a fresh, verified generation on disk
    /// supersedes whatever an earlier failed deletion was protecting
    /// against.
    ///
    /// Returns ``MutationOutcome/stale`` (without having mutated
    /// anything further) the moment any of its own re-checks finds a
    /// more-recently-issued token already authoritative — including one
    /// retired by ``retireIfCurrent(_:for:)`` when the last waiter for
    /// this exact work cancelled. Callers that would otherwise return a
    /// value to their own caller as if this had landed must check this
    /// result (see `AssetCacheService+Fetch.swift`'s and
    /// `AssetCacheService+RevalidationCoalescing.swift`'s use of this).
    @discardableResult
    func publish(
        _ cacheKey: AssetCacheKey,
        asset: CachedAsset,
        token: CacheToken
    ) async -> MutationOutcome {
        guard isAuthoritative(token, for: cacheKey) else { return .stale }
        await memoryCache.set(cacheKey, asset: asset, token: token)
        guard isAuthoritative(token, for: cacheKey) else { return .stale }
        await recordDiskPersistenceResult {
            try await diskCache.set(
                cacheKey,
                payload: asset.payload,
                metadata: asset.metadata,
                token: token
            )
        }
        guard isAuthoritative(token, for: cacheKey) else { return .stale }
        if lastDiskPersistenceFailure == nil {
            tombstonedKeys.remove(cacheKey)
        }
        return .applied
    }

    /// Refreshes an already-cached asset's metadata only (for example
    /// bumping ``AssetCacheMetadata/accessSequence`` after a 304
    /// revalidation), without re-writing the unchanged payload bytes to
    /// disk. Gated by `token` at each hop exactly like ``publish(_:asset:token:)``.
    /// Falls back to the same best-effort, audited failure handling.
    /// Returns ``MutationOutcome/stale`` under the same conditions
    /// ``publish(_:asset:token:)`` does.
    @discardableResult
    func touch(
        _ cacheKey: AssetCacheKey,
        asset: CachedAsset,
        token: CacheToken
    ) async -> MutationOutcome {
        guard isAuthoritative(token, for: cacheKey) else { return .stale }
        await memoryCache.set(cacheKey, asset: asset, token: token)
        guard isAuthoritative(token, for: cacheKey) else { return .stale }
        await recordDiskPersistenceResult {
            try await diskCache.touch(cacheKey, metadata: asset.metadata, token: token)
        }
        guard isAuthoritative(token, for: cacheKey) else { return .stale }
        return .applied
    }

    /// Removes `cacheKey` from both cache layers, tombstoning it if the
    /// disk deletion could not be confirmed to fully succeed (see
    /// ``tombstonedKeys``). Centralizes every disk-invalidating call site
    /// (a definitive 404, a failed re-validation quarantine) so none of
    /// them can accidentally swallow a deletion failure the way a bare
    /// `try?`/best-effort `remove` used to.
    ///
    /// `token` is optional: a re-validation quarantine
    /// (``revalidateDiskHit(_:key:cacheKey:candidates:token:)``'s own
    /// `catch`) still passes its caller's token so this stays gated like
    /// every other mutation, but this is also called with no token at all
    /// from contexts that are not part of any issuance race (there is no
    /// prior in-flight operation whose authority could be superseded).
    /// Returns ``MutationOutcome/stale`` under the same conditions
    /// ``publish(_:asset:token:)`` does (only ever possible when `token`
    /// is non-`nil`: a `nil` token has no authority to lose).
    @discardableResult
    func invalidate(_ cacheKey: AssetCacheKey, token: CacheToken? = nil) async -> MutationOutcome {
        if let token, !isAuthoritative(token, for: cacheKey) {
            return .stale
        }
        // Recorded *before* the memory removal itself (the actual
        // suspension below), so a concurrent reader that snapshotted
        // ``keyClearGeneration`` before this call started will correctly
        // observe a change even if it resumes while this call is still
        // suspended partway through — see ``snapshotClearState(for:)``'s
        // doc comment for why this is deliberately a distinct counter
        // from ``keyLatestToken``.
        keyClearGeneration[cacheKey, default: 0] += 1
        await memoryCache.remove(cacheKey, token: token)
        if let token, !isAuthoritative(token, for: cacheKey) {
            return .stale
        }
        do {
            try await diskCache.remove(cacheKey, token: token)
        } catch {
            tombstonedKeys.insert(cacheKey)
        }
        if let token, !isAuthoritative(token, for: cacheKey) {
            return .stale
        }
        return .applied
    }

    private func recordDiskPersistenceResult(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            lastDiskPersistenceFailure = nil
        } catch let error as AssetError {
            lastDiskPersistenceFailure = error
        } catch {
            lastDiskPersistenceFailure = .cachePersistenceFailed(String(describing: error))
        }
    }
}
