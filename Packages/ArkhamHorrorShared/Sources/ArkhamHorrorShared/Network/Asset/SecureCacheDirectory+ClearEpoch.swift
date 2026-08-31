import Foundation

/// A single, durable, cross-instance/cross-process "cache-wide clear
/// happened" epoch for one cache directory — the counterpart, for whole-
/// cache clears, that ``SecureCacheDirectory/allocateAccessSequence(atLeastAfter:)``
/// already provides for LRU ordering.
///
/// `AssetCacheService/globalGeneration` (see `AssetCacheService+Epoch.swift`)
/// already invalidates every in-process authority token the instant its own
/// ``AssetCacheService/evictAll()`` runs — but that counter lives purely in
/// one actor's own memory. Two independently-wired ``AssetCacheService``
/// instances sharing this same on-disk directory (two OS processes, or —
/// exactly as this package's own tests model it — two independently
/// constructed service instances in one process, each with its own private
/// ``AssetMemoryCache``) each keep their *own* private `globalGeneration`;
/// neither instance's clear ever bumps the other's. Without a durable,
/// shared signal, instance B's fetch — issued before instance A's
/// ``AssetCacheService/evictAll()``, but whose network response only
/// arrives (and is only ready to publish) *after* A's clear has already
/// returned — has no way to learn that a clear happened at all, and would
/// otherwise publish into (and serve straight from) its own untouched
/// memory cache as if nothing had happened, even though the shared cache
/// this directory represents was just told to forget everything.
///
/// This durable epoch closes that gap: every clear commits (write, `fsync`,
/// rename, directory `fsync`) a strictly higher epoch value here — durably,
/// under this directory's cross-process exclusive lock, and *before* any of
/// the clear's own destructive removal work begins (see
/// ``AssetDiskCache/removeAll()``) — and every authority token (see
/// ``AssetCacheService/CacheToken/durableClearEpoch``) captures the epoch
/// value observed at the moment it was issued. Every subsequent authority
/// re-check (``AssetCacheService/isAuthoritative(_:for:)`` and friends)
/// re-reads the *current* epoch and compares it against the value the
/// token captured at issuance — for *every* mutation this token might
/// eventually authorize, including a pure in-memory publish that never
/// itself touches disk on this instance — so an instance that never
/// otherwise learns about another instance's clear still cannot resurrect
/// or newly publish content across it.
///
/// **Durable initialization, not a fold-to-zero default.** A prior
/// revision of this type defaulted a missing file to epoch `0` ("never
/// cleared") for *any* `ENOENT`, on the theory that a freshly created
/// cache root simply has no file yet. That conflated two very different
/// situations that read identically from a bare existence check alone: a
/// genuinely pristine root that has never been opened before, and a root
/// whose durable counter file *existed* (recording one or more real
/// clears) but was since deleted, lost, or otherwise made unreadable —
/// silently reusing `0` for the latter would let a resurrection exactly
/// this file exists to prevent slip through undetected.
///
/// A *later* revision moved initialization into
/// ``SecureCacheDirectory/init(directory:fileManager:)`` itself, on the
/// theory that two racing initializers would always write the exact same
/// content and so no cross-process lock was needed. That reasoning holds
/// only while comparing two initializers racing *against each other* on a
/// root neither has ever touched before — it does not hold once a
/// *third* party (a real, already-completed ``AssetDiskCache/removeAll()``
/// durably bumping the epoch to a real, non-zero value) can interleave
/// between one racing initializer's own "does not exist" read and its own
/// unconditional "write `0`" step: that late writer's unconditional
/// `rename` would silently replace the just-committed, genuinely higher
/// epoch back down to `0`, resurrecting exactly the authority a clear that
/// already, durably happened was supposed to have revoked. Worse, that
/// same unconditional-write shape cannot tell "a genuinely pristine root"
/// apart from "a previously-initialized root whose counter file was later
/// lost" even with no racing initializer in the picture at all — both
/// look identical to a bare existence check taken at any single point in
/// time.
///
/// This revision closes both gaps at once, with two changes:
///
/// 1. Initialization is a genuine cross-process **locked** transaction —
///    see ``ensureRootAuthorityInitializedLocked()`` — run by every
///    ``AssetDiskCache`` locked entry point (never from
///    ``SecureCacheDirectory/init(directory:fileManager:)``, which cannot
///    itself acquire ``acquireExclusiveLock()`` since that is `async`).
///    While one process holds this directory's exclusive lock, no other
///    process can be inside this same transaction at all, eliminating the
///    write-after-read race entirely: a fresh clear can never land between
///    a racing initializer's own read and its own write, because both
///    steps now happen atomically with respect to every other holder of
///    this lock.
/// 2. A separate, permanent **root-init marker** file
///    (``rootInitMarkerFileName``) durably records "this root has been
///    initialized at least once, ever" — created together with, and only
///    together with, the epoch counter's very first value, and never
///    removed by anything (including a whole-cache
///    ``AssetDiskCache/removeAll()``) for the remaining lifetime of this
///    directory. A missing epoch counter is only ever treated as the safe
///    "genuinely pristine root" case when the marker is *also* missing;
///    if the marker exists but the counter does not, this root was
///    definitely initialized before and its counter was definitely lost
///    since — a hard, typed, fail-closed failure, never a silent
///    reinitialization to `0`.
extension SecureCacheDirectory {
    /// The fixed leaf name of this cache's durable clear-epoch counter
    /// file, inside the verified root directory. Not `private`, for the
    /// same reason as ``lockFileName``/``accessSequenceFileName``:
    /// ``AssetDiskCache/removeAll()`` must recognize and preserve this
    /// exact name across the very whole-cache clear it itself is used to
    /// record — deleting it during that same clear would silently reset
    /// every future reader back to "never cleared", exactly undoing the
    /// guarantee this file exists to provide.
    static let clearEpochFileName = ".arkham-cache.clear-epoch"

    /// Fixed-width (20-decimal-digit) encoding width for this file's
    /// value, mirroring ``AssetAccessSequence/digitWidth``'s identical
    /// rationale: a fixed serialized size regardless of the specific
    /// value, and one digit wider than ``AssetAccessSequence`` uses
    /// purely so `Int.max`'s 19-digit decimal representation always has
    /// at least one leading zero-pad digit to spare, keeping the exact
    /// same code path exercised for every value rather than only for
    /// ones that happen to need fewer digits.
    static let clearEpochDigitWidth = 20

    /// The fixed leaf name of this cache's permanent root-init marker
    /// file — see this file's type-level doc comment for exactly what it
    /// durably proves and why a separate file (rather than folding this
    /// into the epoch counter itself) is required. Not `private`, for the
    /// same reason as ``clearEpochFileName``: ``AssetDiskCache/removeAll()``
    /// must recognize and preserve this exact name across a whole-cache
    /// clear — this marker must never be removable by anything, ever, for
    /// the lifetime of this directory.
    static let rootInitMarkerFileName = ".arkham-cache.root-init"

    /// The fixed leaf name of this cache's durable **root-freshness
    /// witness** file — the load-bearing counterpart, for the "was this
    /// root really just created, or did it already exist?" question, that
    /// ``SecureCacheDirectory/rootDirectoryWasFreshlyCreated`` provides
    /// purely in-process. See that property's own doc comment for the
    /// full rationale. Written once, best-effort and unlocked, by
    /// ``SecureCacheDirectory/init(directory:fileManager:)`` itself when
    /// (and only when) that exact call's own `mkdirat` proved it was the
    /// directory's sole creator, and durably retried (under this
    /// directory's cross-process lock, guaranteed to succeed absent an
    /// actual I/O failure) the first time this instance ever runs
    /// ``ensureRootAuthorityInitializedLockedUnwrapped(isSurvivingEntryAcceptable:)``.
    /// Not `private`, for the same reason as every other fixed name in
    /// this file: ``AssetDiskCache/removeAll()`` must recognize and
    /// preserve this exact name across the very whole-cache clear it
    /// itself is used to authorize -- deleting it would permanently and
    /// silently strip this root of its only durable proof of having ever
    /// been fresh, which a later crash/restart could then never recover
    /// from (a used, since-cleared root would incorrectly, permanently,
    /// fail closed on its very next authority-check with no witness
    /// left to consult).
    static let rootFreshnessWitnessFileName = ".arkham-cache.root-freshly-created"

    /// Idempotently ensures this cache directory's durable root authority
    /// — the root-init marker and the clear-epoch counter together — is
    /// fully initialized, as one cross-process locked transaction.
    ///
    /// **Must only ever be called while the caller already holds this
    /// instance's ``acquireExclusiveLock()``** — unlike the prior
    /// unlocked `ensureClearEpochInitialized()` this replaces, callers
    /// (every ``AssetDiskCache`` locked entry point) run this as the
    /// very first step of their own already-held critical section, before
    /// ``AssetDiskCache/recoverOrphansIfNeeded()`` and before any other
    /// read of the durable epoch — see
    /// `AssetDiskCache+RootAuthority.swift`'s call sites.
    ///
    /// The marker and counter's presence are checked **independently**,
    /// not as a single combined branch, and the two durable writes below
    /// are committed in a deliberate order (**counter first, marker
    /// second**) chosen specifically so that every possible crash point
    /// in this transaction is safely, automatically repairable the very
    /// next time this method runs, on any instance/process:
    ///
    /// - **Counter exists.** Always authoritative once present, and
    ///   never rewritten here regardless of the marker's own state. If
    ///   the marker happens to also be missing — a root that predates
    ///   this marker's introduction, or one whose own marker-install step
    ///   crashed immediately after the counter write below durably
    ///   landed but before the marker did — this call installs the
    ///   marker now, without touching the already-durable counter, so
    ///   this root converges on the fully-marked state on its very next
    ///   open rather than silently never acquiring one. Returns either
    ///   way.
    /// - **Counter missing, marker exists.** This root was *definitely*
    ///   initialized before (the marker is only ever installed together
    ///   with, and after, the counter's very first value — see below) —
    ///   so the counter's current absence is definite evidence it was
    ///   lost, deleted, or corrupted away *after* initialization, never a
    ///   safe "pristine root" case. Fails closed with a typed, hard
    ///   failure rather than silently resetting authority back to `0`
    ///   and potentially resurrecting content a clear already durably
    ///   revoked.
    /// - **Counter missing, marker missing.** Only provable, as far as
    ///   this locked transaction can ever tell (no other process can be
    ///   concurrently inside this same method for this same directory
    ///   while this one holds the lock), to be a genuinely fresh root if
    ///   ``rejectSurvivingEntriesForPristineRootLocked(isSurvivingEntryAcceptable:)``
    ///   also finds no entry the caller's own `isSurvivingEntryAcceptable`
    ///   closure does not vouch for — any other name here (a
    ///   `.meta.json`/`.bin`/`.gen`/`.applied`/`.tmp`, or even a durable
    ///   access-sequence counter with no clear-epoch counter beside it)
    ///   that closure does not explicitly accept is definite evidence of
    ///   prior real use whose true clear history this transaction cannot
    ///   recover, and is rejected the same way the "marker exists, counter
    ///   missing" branch above is. Only once that check passes does this
    ///   commit the counter (value `0`)
    ///   *first*, then the marker *second* — the reverse of a prior
    ///   revision's marker-first ordering, which left a crash landing
    ///   strictly between the two steps permanently unrecoverable (marker
    ///   installed, counter missing matches the hard-failure branch above
    ///   forever, bricking the root). Committing the counter first instead
    ///   means that exact same crash window instead lands in the
    ///   self-healing "counter exists, marker missing" branch above on
    ///   the very next call.
    ///
    /// - Parameter isSurvivingEntryAcceptable: Consulted, once per
    ///   surviving non-lock-file entry, only in the "both missing" branch
    ///   above, to decide whether that entry may be tolerated as
    ///   reclaimable debris rather than definite proof of prior real use.
    ///   Defaults to rejecting *every* survivor unconditionally (this
    ///   type's own generic, domain-agnostic policy, exercised directly by
    ///   this type's own unit tests); ``AssetDiskCache`` — the only
    ///   production caller — supplies a domain-aware closure instead (see
    ///   `AssetDiskCache+RootAuthority.swift`).
    func ensureRootAuthorityInitializedLocked(
        isSurvivingEntryAcceptable: (String) throws -> Bool = { _ in false }
    ) throws {
        do {
            try ensureRootAuthorityInitializedLockedUnwrapped(
                isSurvivingEntryAcceptable: isSurvivingEntryAcceptable
            )
        } catch let error as AssetError {
            if case .clearFenceNotDurable = error {
                throw error
            }
            throw AssetError.clearFenceNotDurable(
                "Durable root-authority initialization failed: \(error)"
            )
        }
    }

    private func ensureRootAuthorityInitializedLockedUnwrapped(
        isSurvivingEntryAcceptable: (String) throws -> Bool
    ) throws {
        let epochExists =
            try read(name: Self.clearEpochFileName, maxBytes: Self.clearEpochDigitWidth) != nil
        let markerExists = try read(name: Self.rootInitMarkerFileName, maxBytes: 1) != nil

        if epochExists {
            // Already durably initialized (by this instance or any prior
            // instance/process sharing this directory, at any point in
            // the past, or by a pre-marker version of this package) --
            // the counter itself is never rewritten here. Only the
            // marker -- which carries no authority of its own and is
            // purely a "has this root ever been through this
            // transaction" witness -- may still need installing, so a
            // migrated or partially-crashed root converges on the fully
            // marked state without ever disturbing already-durable
            // authority.
            if !markerExists {
                try installRootInitMarkerLocked()
            }
            return
        }
        guard !markerExists else {
            throw AssetError.clearFenceNotDurable(
                "Clear-epoch counter is missing on a previously initialized cache root; " +
                    "refusing to silently reinitialize its authority"
            )
        }
        // Both authority files are absent. This is the one branch a bare
        // "both missing" existence check can never safely resolve on its
        // own -- it reads identically whether this root is genuinely
        // pristine, or is a previously-used root whose authority files
        // were lost/deleted/corrupted (including, specifically, a root
        // whose *only* surviving entry is
        // ``AssetDiskCache/diskWritesDisabledMarkerName``, an ordinary
        // used-root failure marker with no bearing on freshness at all).
        // Fail closed unconditionally unless this root's freshness can be
        // *proven*, via either of two independent, race-proof signals:
        //
        // 1. `rootDirectoryWasFreshlyCreated` -- this exact in-process
        //    instance's own `mkdirat` won the race to create this
        //    directory, moments ago, in `init`.
        // 2. The durable ``rootFreshnessWitnessFileName`` file --
        //    written (possibly by a *different*, now-gone instance/
        //    process, at its own `init` time) the moment *that* creator
        //    observed the same in-process proof this one checks in (1).
        //
        // No other survivor, regardless of name -- including a
        // "recognized" name like the disk-writes-disabled marker -- may
        // ever substitute for either of these: a used root can contain
        // arbitrary combinations of recognized filenames purely because
        // it was used and later partially swept, which is exactly the
        // deceptive case this gate exists to reject.
        let witnessExists =
            try read(name: Self.rootFreshnessWitnessFileName, maxBytes: 1) != nil
        guard rootDirectoryWasFreshlyCreated || witnessExists else {
            throw AssetError.clearFenceNotDurable(
                "Cache root has no durable or in-process proof of first-ever creation; " +
                    "refusing to treat a root with no verifiable freshness witness as pristine, " +
                    "regardless of which entries it currently contains"
            )
        }
        // Freshness is now proven. Any *other* survivor is still
        // descriptor-validated as defense-in-depth (a bug or foreign
        // writer landing inside a provably fresh root before authority
        // finished initializing would be surprising and worth rejecting)
        // -- but, unlike before this fix, is never itself the thing that
        // authorizes treating this root as pristine; that authorization
        // already came entirely from the freshness proof above.
        try rejectSurvivingEntriesForPristineRootLocked(
            isSurvivingEntryAcceptable: isSurvivingEntryAcceptable
        )
        // This locked transaction is also the durable retry point for the
        // best-effort, unlocked witness write `init` already attempted:
        // if that earlier write failed (or this instance is a survivor of
        // a still-durable witness written by a now-gone prior instance),
        // commit it now, under this directory's cross-process lock, where
        // a failure is a real, typed I/O error rather than silently
        // swallowed.
        if !witnessExists {
            try installRootFreshnessWitnessLocked()
        }
        // Counter first, marker second -- see this method's own doc
        // comment for why this exact order is what makes a crash
        // strictly between the two steps land in the self-healing
        // "counter exists, marker missing" branch above on the very next
        // call, rather than the permanently-fail-closed "marker exists,
        // counter missing" branch.
        try persistClearEpoch(0)
        try installRootInitMarkerLocked()
    }
}
