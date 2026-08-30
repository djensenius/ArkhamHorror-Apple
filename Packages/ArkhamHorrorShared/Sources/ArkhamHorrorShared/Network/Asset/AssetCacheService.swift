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
    ///
    /// `nextGlobalIssuance` is a single counter shared across *every*
    /// key — deliberately not a per-key counter restarting from zero —
    /// so that ``pruneAuthorityKeysIfNeeded()`` discarding a key's
    /// bookkeeping and a later fresh operation for that same key
    /// restarting it can never mint an `issuance` value that collides
    /// with one an older, still-suspended snapshot/token for the same
    /// key (from before the prune) might still be holding — see
    /// ``issueToken(for:)``.
    var nextGlobalIssuance = 0
    var keyLatestToken: [AssetCacheKey: CacheToken] = [:]
    var globalGeneration = 0
    var inFlightRevalidation: [RevalidationSlot: RevalidationFetch] = [:]

    /// Bumped for exactly `key` every time ``invalidate(_:token:)``
    /// actually proceeds to remove it (a definitive 404, a failed
    /// re-validation quarantine, or a URL-mismatch quarantine) — folded
    /// into every issued ``CacheToken``'s own `clearGeneration` field and
    /// checked by the single, unified ``isAuthoritative(_:for:)``/
    /// ``unchanged(since:for:)`` pair every caller already uses (see
    /// `AssetCacheService+Epoch.swift`), rather than a separate, narrower
    /// check some callers previously used and others did not.
    var keyClearGeneration: [AssetCacheKey: Int] = [:]

    /// Reference counts of currently-open "authority windows" per key —
    /// see ``beginAuthorityWindow(for:)``/``endAuthorityWindow(for:)`` in
    /// `AssetCacheService+Epoch.swift`.
    var openAuthorityWindows: [AssetCacheKey: Int] = [:]

    /// The maximum number of distinct keys' authority bookkeeping
    /// (``keyLatestToken``/``keyClearGeneration``) this actor retains at
    /// once, before pruning the least-recently-touched entries — see
    /// ``authorityKeyOrder``/``noteAuthorityKeyTouched(_:)`` in
    /// `AssetCacheService+Epoch.swift`. Every one of those dictionaries is
    /// keyed by an ``AssetCacheKey`` that (for a self-hosted server, or a
    /// homebrew card/campaign identifier) is ultimately derived from
    /// server-controlled or user-supplied input, not a small, fixed,
    /// first-party enumeration — an unbounded stream of distinct
    /// never-repeated keys would otherwise grow these dictionaries
    /// without limit for the lifetime of the process. A pruned key's
    /// bookkeeping simply restarts from scratch (no recorded latest
    /// token, clear generation `0`) the next time it is genuinely
    /// requested again — never pruned, however, while any fetch,
    /// revalidation, or other open authority window (see
    /// ``beginAuthorityWindow(for:)``) is actually live for it, so a live
    /// operation's own authority can never be silently discarded out from
    /// under it purely due to unrelated keys' churn.
    static let maxTrackedAuthorityKeys = 4096

    /// First-seen-insertion-order list of every key currently tracked
    /// across ``keyLatestToken``/``keyClearGeneration`` — oldest first.
    /// Deliberately *not* re-ordered on every subsequent touch of an
    /// already-tracked key (an O(1) append on first sight, rather than an
    /// O(n) linear-scan-and-move-to-the-end on every single token
    /// issuance): pruning only needs *some* inactive key to reclaim, not
    /// the precise least-recently-used one, so plain insertion order is
    /// sufficient. Paired with ``trackedAuthorityKeys`` (a `Set` mirror,
    /// so "is this key already tracked" is an O(1) check rather than an
    /// O(n) scan of this array). See ``noteAuthorityKeyTouched(_:)``.
    var authorityKeyOrder: [AssetCacheKey] = []
    var trackedAuthorityKeys: Set<AssetCacheKey> = []

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

    /// Test-only hook invoked by ``recordDiskPersistenceResult(_:)``
    /// immediately after it has finished updating
    /// ``lastDiskPersistenceFailure`` (whether that update happened or,
    /// for a cancelled attempt, deliberately did not) — see that
    /// function's own doc comment. Always `nil` in production; a test
    /// installs a closure here to deterministically wait for that exact
    /// disk-persistence bookkeeping to have completed before inspecting
    /// ``lastDiskPersistenceFailure``, rather than racing it via the
    /// unrelated timing of when a coalesced waiter's own continuation
    /// happens to resume.
    var testOnlyDiskPersistenceRecordedHook: (() -> Void)?

    /// Test-only hook awaited by ``revalidate(for:)``'s validated-disk-hit
    /// branch immediately after it has re-verified `token`'s authority
    /// following the decode in ``revalidateDiskHit(_:key:cacheKey:candidates:token:)``,
    /// and immediately before carrying that same token through to the
    /// conditional revalidation network step. Always `nil` in
    /// production. A test installs a closure here to deterministically
    /// suspend at that exact point — a point that is otherwise reached
    /// and left synchronously, with no other genuine suspension in
    /// between — so a concurrent ``evictAll()``/``invalidate(_:token:)``
    /// can be driven to completion in between the check and the network
    /// step in a reproducible regression test, rather than depending on
    /// incidental actor-scheduling timing.
    var testOnlyPauseBeforeRevalidationRequest: (() async -> Void)?

    /// Test-only hook awaited immediately after a `publish(_:asset:token:)`
    /// call has already returned ``MutationOutcome/applied`` — i.e. a
    /// resolved asset has already genuinely landed in both cache layers
    /// under `token` — and immediately before the caller returns that
    /// asset onward: both ``validateAndPublish(candidate:url:cacheKey:token:response:)``
    /// (a plain cache-miss fetch, in `AssetCacheService+Fetch.swift`) and
    /// `performRevalidation(_:)`'s own `.success` branch (a conditional
    /// revalidation's fresh-200 outcome, in
    /// `AssetCacheService+RevalidationCoalescing.swift`) await this same
    /// hook at their own identical point, since both are the shared
    /// `Task` body a coalesced fetch/revalidation's cancellation handling
    /// must retract an already-applied mutation from, regardless of
    /// which of the two produced it. Always `nil` in production. A test
    /// installs a closure here to deterministically force exactly the
    /// ordering ``cancelWaiter(_:fetchID:waiterID:)``'s (and
    /// ``cancelRevalidationWaiter(_:fetchID:waiterID:)``'s) doc comments
    /// describe as previously unprotected: the underlying mutation has
    /// *already* committed successfully by the time a concurrent
    /// last-waiter cancellation reaches this actor, rather than racing
    /// that ordering via incidental scheduling timing.
    var testOnlyPauseAfterFetchPublishApplied: (() async -> Void)?

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
    ///
    /// A *memory* hit (already proven fresh earlier in this exact process
    /// run, and never surviving a restart) is returned immediately. A
    /// *disk-only* hit is different: this cache does not attempt to
    /// durably order writes across separate processes/instances sharing
    /// the same disk directory (see ``AssetDiskCache``'s doc comment), so
    /// persisted bytes from a possibly-different prior process are never
    /// independently trusted as still-fresh, offline-authoritative
    /// content — they are, at best, a conditional-revalidation candidate.
    /// Every disk-only hit must therefore pass the exact same structural
    /// re-validation as ``AssetCacheService/revalidateDiskHit(_:key:cacheKey:candidates:token:)``
    /// already performs, *and* a fresh online conditional
    /// (`ETag`/`Last-Modified`) revalidation against the live server,
    /// before it may ever be cached in memory or returned to a caller. If
    /// no validator is available at all (or the structural check already
    /// failed, or authority was lost mid-decode), this falls through to
    /// an ordinary unconditional fetch exactly as if this had been a
    /// clean cache miss — never silently serving unverified offline bytes.
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
        // actor-hop timing luck. Wrapped in an authority window so this
        // key's bookkeeping cannot be pruned while this snapshot is still
        // suspended awaiting `memoryCache.get`.
        beginAuthorityWindow(for: cacheKey)
        let memorySnapshot = await snapshotAuthority(for: cacheKey)
        let memoryHit = await memoryCache.get(cacheKey)
        var memoryHitIsCurrent = false
        if memoryHit != nil {
            memoryHitIsCurrent = await unchanged(since: memorySnapshot, for: cacheKey)
        }
        endAuthorityWindow(for: cacheKey)
        if let cached = memoryHit, memoryHitIsCurrent {
            return cached
        }
        if let diskResult = try await diskHitIfTrusted(
            key: key,
            cacheKey: cacheKey,
            candidates: candidates
        ) {
            return diskResult
        }
        return try await coalescedFetch(key: key, cacheKey: cacheKey, candidates: candidates)
    }

    /// Test-only: installs ``testOnlyDiskPersistenceRecordedHook``.
    /// A plain actor-isolated method (rather than exposing the stored
    /// property for direct external assignment) so a test's call site
    /// reads as an ordinary, obviously-`await`-requiring actor call.
    func installTestOnlyDiskPersistenceRecordedHook(_ hook: @escaping () -> Void) {
        testOnlyDiskPersistenceRecordedHook = hook
    }

    /// Test-only: installs ``testOnlyPauseBeforeRevalidationRequest``.
    func installTestOnlyPauseBeforeRevalidationNetworkStep(_ hook: @escaping () async -> Void) {
        testOnlyPauseBeforeRevalidationRequest = hook
    }

    /// Test-only: installs ``testOnlyPauseAfterFetchPublishApplied``.
    func installTestOnlyPauseAfterFetchPublishApplied(_ hook: @escaping () async -> Void) {
        testOnlyPauseAfterFetchPublishApplied = hook
    }
}
