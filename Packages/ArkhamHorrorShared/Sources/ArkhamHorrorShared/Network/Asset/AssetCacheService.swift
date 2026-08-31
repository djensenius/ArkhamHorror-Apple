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

    /// Retained bookkeeping for a coalesced fetch whose completion
    /// watcher (``completeFetch(_:fetchID:result:)``) has already
    /// resumed every currently-registered waiter, until each of those
    /// waiters has individually finalized — keyed by `fetchID`, not
    /// cache key; see `AssetCacheService+WaiterAcknowledgement.swift`'s
    /// type-level doc comment for the full reasoning.
    var pendingFetchAcknowledgement: [UUID: PendingWaiterAcknowledgement<AssetCacheKey>] = [:]

    /// Mirrors ``pendingFetchAcknowledgement`` for coalesced
    /// revalidations, keyed the same way.
    var pendingRevalidationAcknowledgement:
        [UUID: PendingWaiterAcknowledgement<RevalidationSlot>] = [:]

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

    /// Per-``AssetCacheKey`` reference count of currently-registered
    /// ``inFlightRevalidation`` slots — kept in exact lockstep with every
    /// insertion/removal of an ``inFlightRevalidation`` entry via
    /// ``setInFlightRevalidation(_:for:)``/``clearInFlightRevalidation(for:)``
    /// (the only two mutation points; never write ``inFlightRevalidation``
    /// directly). This exists purely so ``isAuthorityKeyBusy(_:)`` can
    /// answer "does this cache key have any revalidation in flight?" as a
    /// single O(1) dictionary lookup, rather than
    /// `inFlightRevalidation.keys.contains(where: { $0.cacheKey == key })`
    /// — an O(m) linear scan of every currently in-flight revalidation
    /// slot (potentially for entirely unrelated keys, since a
    /// ``RevalidationSlot`` also carries the URL/validator, not just the
    /// cache key). Run once per key considered during
    /// ``pruneAuthorityKeysIfNeeded(protecting:)``'s pass, that O(m) scan
    /// made a sustained high-cardinality-churn burst (many distinct keys,
    /// many concurrent revalidations) quadratic overall; this refcount
    /// makes the whole pass, and every single touch, amortized O(1).
    var revalidationKeyRefCount: [AssetCacheKey: Int] = [:]

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

    /// Defensive ceiling on how many strictly-increasing tickets
    /// ``AssetCacheService/ticketGapIsEntirelyAbandoned(from:downTo:for:)``
    /// will walk, one confirmed-retiring lookup at a time, for a single
    /// cache key's own gap between a stored memory entry's ``CachedAsset/writeGeneration``
    /// and that key's current durable highest-issued ticket — see that
    /// method's own doc comment for why this walk exists at all. A gap
    /// this wide for one key, within one durable clear epoch, would mean
    /// thousands of distinct issue-then-abandon cycles for that exact
    /// key alone; failing closed beyond it costs nothing but one
    /// unconditional live revalidation for a pathological key, never an
    /// unbounded synchronous walk.
    static let maxRetiringGapWalk = 256

    /// First-seen-insertion-order list of every key currently tracked
    /// across ``keyLatestToken``/``keyClearGeneration`` — oldest first.
    /// Deliberately *not* re-ordered on every subsequent touch of an
    /// already-tracked key (an O(1) append on first sight, rather than an
    /// O(n) linear-scan-and-move-to-the-end on every single token
    /// issuance): pruning only needs *some* inactive key to reclaim, not
    /// the precise least-recently-used one, so plain insertion order is
    /// sufficient. Paired with ``trackedAuthorityKeys`` (a `Set` mirror,
    /// so "is this key already tracked" is an O(1) check rather than an
    /// O(n) scan of this array). Backed by ``AuthorityKeyQueue`` (an
    /// amortized-O(1)-`append`/`popFirst` FIFO), not a bare `Array`,
    /// specifically so a sustained all-keys-busy burst at
    /// ``maxTrackedAuthorityKeys`` capacity — every touch during it
    /// forced to scan and requeue the same busy keys — costs the same
    /// constant amortized work per touch it always has, rather than
    /// `Array.removeFirst()`'s O(n) element shift turning that burst
    /// quadratic. See ``noteAuthorityKeyTouched(_:)``.
    var authorityKeyOrder = AuthorityKeyQueue<AssetCacheKey>()
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

    /// Per-key set of disk write-generation tickets whose own mutation
    /// has been *decided* to be retracted (a cancelled coalesced fetch/
    /// revalidation's last waiter leaving, or a completed one every
    /// waiter finalized without ever taking delivery of) — see
    /// ``markGenerationRetiring(_:for:)`` in `AssetCacheService+Epoch.swift`.
    ///
    /// **Why this exists at all, alongside ``keyLatestToken``/
    /// ``retireIfCurrent(_:for:)``.** Retiring a token there only ever
    /// prevents a *future* mutation under that same token; it says
    /// nothing about a mutation the doomed operation's own body already
    /// applied to memory/disk strictly *before* the decision to retract
    /// was made. That already-applied entry's own durable stamps
    /// (``AssetCacheMetadata/clearEpochAtPublication``/
    /// ``writeGenerationAtPublication``) are, by construction,
    /// completely unaffected by retiring a token or by the fact that a
    /// retraction has been decided at all — nothing else has been issued
    /// for this key, so every durable authority check
    /// (``memoryEntryStillCurrent(_:storedGeneration:for:)``,
    /// ``AssetDiskCache/acceptToken(_:currentEpoch:currentIssued:)``)
    /// would otherwise keep reporting that exact entry "still current"
    /// indefinitely — a window a concurrent ``asset(for:)``/
    /// ``revalidate(for:)`` call could otherwise read straight through,
    /// serving a value this actor has already promised its own sole
    /// caller (the one who just cancelled, or every one of whom already
    /// walked away without delivery) will never survive. Recording the
    /// exact retracted ticket here, *synchronously*, at the same moment
    /// the decision to retract is made — always strictly before the
    /// first `await` of the actual removal — closes that window: any
    /// memory hit whose own stamped generation exactly matches an entry
    /// in this set for its key is unconditionally treated as not current.
    ///
    /// **Deliberately never individually cleared once the corresponding
    /// removal actually completes — see ``markGenerationRetiring(_:for:)``'s
    /// own doc comment for why eagerly clearing on completion is
    /// itself unsound** (a concurrent reader that already captured this
    /// exact entry, strictly before the removal ran, could still be
    /// suspended somewhere between that capture and its own authority
    /// check for arbitrarily long afterward). Bounded instead exactly
    /// like ``keyLatestToken``/``keyClearGeneration``: pruned in the same
    /// bundle, for the same key, by the same
    /// `AssetCacheService+AuthorityPruning.swift` mechanism, which
    /// already refuses to prune any key with an open authority window or
    /// a live in-flight operation — the same protection that already
    /// keeps a still-suspended reader's own snapshot safe.
    var retiringGenerations: [AssetCacheKey: Set<Int>] = [:]

    /// Per-``AssetCacheKey`` FIFO mutex backing store for
    /// ``acquireIssuanceDecisionLock(for:)``/``releaseIssuanceDecisionLock(for:)``
    /// in `AssetCacheService+IssuanceDecisionLock.swift`: `true` (present
    /// in this set) while some caller currently holds `key`'s lock, and
    /// the paired dictionary of still-queued waiters (in arrival order)
    /// for it. See that file's type-level doc comment for why this
    /// exists at all — it closes a wasteful, and in one case actively
    /// fencing, duplicate disk-ticket-reservation hazard that plain
    /// actor reentrancy alone otherwise allows.
    var issuanceDecisionLocked: Set<AssetCacheKey> = []
    var issuanceDecisionWaiters: [AssetCacheKey: [QueuedIssuanceDecisionWaiter]] = [:]

    /// Monotonically increasing source for
    /// ``QueuedIssuanceDecisionWaiter/id``, so a cancellation handler
    /// firing on an arbitrary executor can find and remove *this exact*
    /// queued waiter (never some other, still-legitimately-waiting one)
    /// from ``issuanceDecisionWaiters`` — mirrors
    /// ``SecureCacheDirectoryLockCoordinator``'s identical `nextWaiterID`
    /// convention, for the identical reason.
    var nextIssuanceDecisionWaiterID = 0

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

    /// Test-only hook awaited by ``asset(for:)``'s/``revalidate(for:)``'s
    /// memory-hit branches immediately after both of their own durable
    /// checks (``unchanged(since:for:)``/``clearStateUnchanged(since:for:)``
    /// and ``memoryEntryStillCurrent(_:storedGeneration:for:)``) already
    /// completed, and immediately *before* the final synchronous
    /// ``localAuthorityStillMatchesSync(_:for:)``/
    /// ``localClearStateStillMatchesSync(_:for:)`` re-check. Always `nil`
    /// in production. A test installs a closure here to deterministically
    /// drive a concurrent same-actor ``evictAll()``/``invalidate(_:token:)``
    /// to completion in exactly this window, confirming the final
    /// synchronous re-check (not either durable check) rejects the
    /// now-superseded memory hit.
    var testOnlyPauseBeforeMemoryFinalCAS: (() async -> Void)?

    /// Test-only hook awaited by ``resolveOrCreateInFlightFetch(key:cacheKey:candidates:)``
    /// immediately after it acquires `cacheKey`'s issuance decision lock
    /// (``acquireIssuanceDecisionLock(for:)``) but before it inspects
    /// ``inFlight`` or reserves any disk authority — i.e. while this
    /// caller alone still holds that key's lock. Always `nil` in
    /// production. A test installs a closure here to deterministically
    /// hold this lock open long enough for a second, concurrent caller
    /// for the identical key to genuinely become queued behind it (via
    /// ``AssetCacheService/issuanceDecisionWaiters``) and then be
    /// cancelled while still queued, proving
    /// ``acquireIssuanceDecisionLock(for:)``'s cancellation handling
    /// resumes that exact queued waiter with `CancellationError` — never
    /// silently handing it the lock once its turn eventually comes —
    /// without relying on incidental scheduling timing alone.
    var testOnlyPauseHoldingIssuanceLock: (() async -> Void)?

    /// Test-only hook invoked by ``completeFetch(_:fetchID:result:)``
    /// synchronously, before it resumes any of the fetch's currently
    /// registered waiters — see
    /// `AssetCacheService+WaiterAcknowledgement.swift`'s type-level doc
    /// comment for the exact hazard this lets a test deterministically
    /// reproduce (a waiter's own task cancelled after the shared fetch
    /// has already succeeded, rather than while it is still pending).
    /// Always `nil` in production.
    var testOnlyBeforeFetchResumesWaiters: (() -> Void)?

    /// Test-only hook invoked by ``completeRevalidation(_:fetchID:result:)``
    /// — the revalidation counterpart to
    /// ``testOnlyBeforeFetchResumesWaiters``. Always `nil` in
    /// production.
    var testOnlyBeforeRevalidationResumesWaiters: (() -> Void)?

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
}
