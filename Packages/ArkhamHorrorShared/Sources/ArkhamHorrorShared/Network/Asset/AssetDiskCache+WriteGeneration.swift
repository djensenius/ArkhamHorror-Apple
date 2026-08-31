import Foundation

/// The durable, cross-instance/cross-process per-key **issuance** and
/// **applied** ticket counters for `AssetDiskCache` — the disk-side half
/// of the compare-and-swap that closes this package's most persistently-
/// flagged review finding: a purely actor-local (in-memory) applied-token
/// dictionary cannot tell two *independent* `AssetCacheService`/
/// `AssetDiskCache` instances (two OS processes, or two independently
/// constructed instances in one process, each pointed at this same
/// on-disk directory) apart at all — each keeps its own private in-memory
/// state, so an older instance's delayed write/removal has no way to
/// learn a newer instance already concluded for the exact same key, and
/// vice versa.
///
/// **Two separate durable counters per key, not one.** An earlier
/// revision of this mechanism used a single counter file, read (never
/// reserved) at issuance time and compared for *exact* equality at
/// publish time. That is completion-ordered, not issuance-ordered: two
/// operations issued at nearly the same moment, before either has
/// published, both read the *same* current value (nothing has changed
/// yet), so whichever one happens to *complete* first "wins" the
/// equality check and advances the counter — and the other, genuinely
/// issued *after* it, then finds the counter has moved past its own
/// stale snapshot and is wrongly rejected, even though it should be the
/// one to win. This revision instead keeps:
///
/// - ``issueTicketLocked(for:)`` (called by ``beginIssuance(for:)``):
///   durably reserves a fresh, strictly-increasing, never-reused ticket
///   for `key` the moment an operation is *issued* — before it ever
///   suspends for network I/O or a decode — so two concurrently-issued
///   operations for the same key always receive two distinct,
///   totally-ordered tickets, never the same snapshot value.
/// - ``currentAppliedTicketLocked(for:)``/``commitPublicationLocked(for:token:contentHash:)``:
///   a *separate* durable counter — now embedded in a typed
///   ``KeyDisposition`` (see `AssetDiskCache+Disposition.swift`) rather
///   than a bare integer, so a retraction/removal can record *which kind*
///   of disposition (`content`/`retiring`/`tombstone`) is currently
///   applied, not merely a ticket number — recording the highest ticket
///   any mutation for `key` has actually committed (published, touched,
///   or removed). ``AssetDiskCache/acceptToken(_:currentEpoch:currentIssued:)``
///   itself compares an operation's own issued ticket by *exact equality*
///   against the highest ticket ever *issued* for this key
///   (``currentIssuedTicketLocked(for:)``), never against this applied
///   counter directly — see that method's own doc comment for why
///   issued, not applied, is the correct comparison target, and why
///   exact equality, not `>=`, is required. A higher-ticketed
///   (later-issued) operation always outranks a lower-ticketed one
///   regardless of which one's network round trip or decode happens to
///   finish first; an operation whose own ticket is no longer the
///   single most recently issued one is unconditionally stale.
///
/// Both counters live entirely separate from the key's
/// ``AssetCacheMetadata`` sidecar: that sidecar is deleted the instant a
/// key's entry is definitively removed (a 404 invalidation, a failed
/// re-validation quarantine), and reusing either counter's storage there
/// would let "no entry currently exists" collapse back to the exact same
/// baseline value (`0`) an operation issued *before this key had ever
/// been written at all* also captured — indistinguishable from a
/// genuinely pristine key, and so wrongly able to resurrect content
/// after a legitimate removal if that very first, still-suspended
/// operation's own response happens to arrive after both a full write and
/// a subsequent removal have already completed for the same key. Neither
/// counter file is ever deleted by an ordinary per-key
/// ``AssetDiskCache/remove(_:token:)`` — only ``AssetDiskCache/removeAll()``
/// (which is always paired with a durable clear-epoch bump any stale
/// token is independently and unconditionally rejected by; see
/// `SecureCacheDirectory+ClearEpoch.swift`) ever removes them, so a key's
/// write-ordering history survives an ordinary content removal exactly as
/// long as it needs to.
///
/// Every successful mutation (``AssetDiskCache/set(_:payload:metadata:token:)``,
/// ``AssetDiskCache/touch(_:metadata:token:)``, ``AssetDiskCache/remove(_:token:)``)
/// — even one called with no external `token` at all (test-only direct
/// actor access) — reserves and commits its *own* fresh ticket via
/// ``commitPublicationLocked(for:token:contentHash:)``/
/// ``commitRetractionLocked(for:token:destroy:)`` immediately before (a
/// content publication) or as part of (a retraction's own two-phase
/// commit) it actually mutates disk state, and that freshly reserved
/// ticket (always strictly greater than whatever was previously applied,
/// by construction: a ticket is only ever reserved by bumping the same
/// monotonic counter ``issueTicketLocked(for:)`` itself draws from)
/// becomes the new applied value. This is what makes even an
/// *unconditional* removal (no `token` supplied) permanently and
/// correctly reject a later replay of a `token` issued before that
/// removal: the replayed token's own ticket can never again be `>=` the
/// applied ticket that removal itself just committed.
extension AssetDiskCache {
    static let ticketDigitWidth = 20

    /// The fixed leaf name of `key`'s durable issuance-ticket counter
    /// file — the source of every fresh ticket ever reserved for `key`,
    /// via ``issueTicketLocked(for:)`` alike. Key-hash-derived only
    /// (never from any other input), so it is always a single,
    /// traversal-proof leaf name, exactly like
    /// ``metadataFilename(for:)``/``payloadFilename(keyHash:contentHash:)``.
    func writeGenerationFilename(for key: AssetCacheKey) -> String {
        "\(key.digestHex).gen"
    }

    /// The fixed leaf name of `key`'s durable *applied* ticket counter
    /// file — the highest ticket any mutation for `key` has actually
    /// committed. Not directly consulted by
    /// ``AssetDiskCache/acceptToken(_:currentEpoch:currentIssued:)``,
    /// which compares against the highest *issued* ticket instead — see
    /// that method's own doc comment.
    func appliedTicketFilename(for key: AssetCacheKey) -> String {
        "\(key.digestHex).applied"
    }

    /// A single, atomic, cross-instance/cross-process issuance snapshot
    /// for `key`: the durable clear epoch and a freshly reserved,
    /// strictly-increasing, never-reused ticket for this key's own
    /// durable issuance counter, read/reserved together under one
    /// exclusive-lock acquisition. Called exactly once, as the very first
    /// step of issuing a fresh (never coalesced-into) fetch/revalidation/
    /// disk-hit operation — *before* the synchronous "check the
    /// coalescing dictionary, else create and issue" decision that
    /// follows it (see `AssetCacheService+Coalescing.swift`/
    /// `AssetCacheService+Revalidation.swift`) — so the resulting
    /// ``AssetCacheService/CacheToken`` can be fully stamped,
    /// synchronously, at the moment it is actually issued, rather than
    /// being restamped later from a value re-read after an unrelated
    /// suspension (the exact TOCTOU gap a prior review specifically
    /// flagged: "durable epoch captured after operation issuance").
    ///
    /// Unlike a prior revision, this *reserves* (durably bumps) the
    /// ticket rather than merely reading the current value: two
    /// operations issued concurrently, before either has published, now
    /// always receive two distinct, totally-ordered tickets — never the
    /// same snapshot — which is what lets a later-issued operation always
    /// outrank an earlier-issued one regardless of completion order (see
    /// this file's own type-level doc comment).
    ///
    /// Throws (fail closed) on any read/write failure for either value —
    /// callers treat a failed snapshot identically to an unstamped token:
    /// permanently non-authoritative, never a silent default.
    struct IssuanceSnapshot: Sendable {
        let clearEpoch: Int
        let writeGeneration: Int
    }

    func beginIssuance(for key: AssetCacheKey) async throws -> IssuanceSnapshot {
        let lockFD = try await secureDirectory.acquireExclusiveLock()
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        try ensureRootAuthorityInitializedLocked()
        let epoch = try secureDirectory.readPersistedClearEpoch()
        let ticket = try issueTicketLocked(for: key)
        return IssuanceSnapshot(clearEpoch: epoch, writeGeneration: ticket)
    }

    /// The revalidation counterpart to ``beginIssuance(for:)``, used
    /// whenever the operation being issued is re-validating an *already
    /// cached* entry (rather than starting a brand-new, no-prior-bytes
    /// fetch) — the memory-hit/disk-hit branches of
    /// `AssetCacheService+Revalidation.swift`/`+DiskHit.swift`/
    /// `+RevalidationDiskFetch.swift`.
    ///
    /// Two genuinely different concerns are resolved atomically, under
    /// one lock hold, rather than being conflated into one value:
    ///
    /// 1. **Provenance validation.** `expectedClearEpoch`/
    ///    `expectedAppliedTicket` are the cached entry's own *historical*
    ///    publication stamp (``AssetCacheMetadata/clearEpochAtPublication``/
    ///    ``AssetCacheMetadata/writeGenerationAtPublication``, threaded
    ///    through from ``AssetMemoryCache/CachedAsset/durableClearEpoch``/
    ///    ``AssetMemoryCache/CachedAsset/writeGeneration``) — fixed at the
    ///    moment those exact bytes were last confirmed good. Compared,
    ///    under this same lock, against the *current* durable epoch and
    ///    this key's *currently applied* ticket
    ///    (``currentAppliedTicketLocked(for:)``, not
    ///    ``currentIssuedTicketLocked(for:)`` — provenance cares whether
    ///    a mutation has actually *landed* for this key since, not
    ///    merely whether some other operation has been issued but not yet
    ///    applied). A mismatch on either half means this exact cached
    ///    entry is no longer the durable state of record — a
    ///    cross-instance clear, or a competing write for this same key,
    ///    landed at some point after these bytes were last confirmed
    ///    good — and this returns `nil` rather than any snapshot at all:
    ///    the caller must treat that identically to "no trustworthy
    ///    cached entry" and fall through to a full, uncached fetch,
    ///    never attempt to revalidate (pair a conditional request/304
    ///    with) bytes whose own provenance no longer matches durable
    ///    reality.
    ///
    ///    Performed in the *same* lock acquisition, immediately before
    ///    reserving a fresh ticket below, specifically so there is no
    ///    separate suspending round trip between "confirm this entry's
    ///    provenance still matches current durable state" and "reserve
    ///    this operation's own fresh authority" for a cross-instance
    ///    clear or competing write to land invisibly inside. A prior
    ///    revision instead threaded the entry's *own* historical stamp
    ///    through directly as the new operation's token authority — that
    ///    closed the provenance-laundering gap this method closes, but at
    ///    the cost of a different, more severe defect: a revalidation
    ///    that reuses a stale, already-applied ticket verbatim as its own
    ///    "freshly issued" authority is, by definition, *not* a value
    ///    uniquely reserved for this operation, and ``removeIfApplied(_:token:)``'s
    ///    exact-match cancellation-retraction contract silently breaks —
    ///    it can no longer distinguish "this exact cancelled operation's
    ///    own applied mutation" from "the entry's already-correct,
    ///    untouched applied state," and would incorrectly retract a
    ///    perfectly valid, unrelated entry the instant an in-flight
    ///    revalidation that never itself wrote anything is cancelled.
    ///
    /// 2. **Fresh per-operation authority.** Once provenance is confirmed
    ///    unchanged, this reserves a genuinely fresh, strictly-increasing,
    ///    never-reused ticket for `key` (``issueTicketLocked(for:)``) —
    ///    identical in kind to ``beginIssuance(for:)``'s own reservation
    ///    — so this operation's own token is always uniquely its own,
    ///    never coincidentally equal to whatever is already the applied
    ///    ticket, preserving every other CAS/cancellation-retraction
    ///    invariant this file's type-level doc comment describes.
    ///
    /// Throws (fail closed, exactly like ``beginIssuance(for:)``) on any
    /// durable read/write failure; returns `nil` (a distinct, non-throwing
    /// "safe to fall through, nothing durably wrong happened" outcome)
    /// only for a genuine provenance mismatch.
    /// **Compares `key`'s full durable disposition, not merely its
    /// ticket.** A bare ticket-equality check here is unsound on its own:
    /// ``AssetDiskCache/commitRetractionLocked(for:token:destroy:)``
    /// durably commits a `.retiring`/`.tombstone` disposition for
    /// *exactly* the same ticket the content it is retracting was
    /// published under (a token-gated retraction reuses its own token's
    /// already-issued ticket verbatim -- see that method's own doc
    /// comment) -- so a stale cached entry whose historical stamp
    /// happens to equal that unchanged ticket value would otherwise still
    /// pass this check even though the content it once pointed to has
    /// since been definitively torn down, letting a revalidation
    /// (touch/304) proceed against -- and potentially resurrect
    /// authority over -- content that is durably gone. Requiring
    /// ``AssetDiskCache/KeyDispositionKind/content`` here closes that
    /// window: only a disposition that is *still* a live content
    /// publication, at exactly this ticket, can ever pass. `expectedContentHash`,
    /// when supplied, is compared too, as a further belt-and-suspenders
    /// check against the exact bytes this operation's own historical
    /// stamp was captured alongside.
    func beginRevalidationIssuance(
        for key: AssetCacheKey,
        expectedClearEpoch: Int,
        expectedAppliedTicket: Int,
        expectedContentHash: String? = nil
    ) async throws -> IssuanceSnapshot? {
        let lockFD = try await secureDirectory.acquireExclusiveLock()
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        try ensureRootAuthorityInitializedLocked()
        let epoch = try secureDirectory.readPersistedClearEpoch()
        let disposition = try currentDispositionLocked(for: key)
        guard
            epoch == expectedClearEpoch,
            disposition.kind == .content,
            disposition.ticket == expectedAppliedTicket,
            expectedContentHash == nil || disposition.contentHash == expectedContentHash
        else {
            return nil
        }
        let ticket = try issueTicketLocked(for: key)
        return IssuanceSnapshot(clearEpoch: epoch, writeGeneration: ticket)
    }
}
