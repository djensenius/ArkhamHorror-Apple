import Foundation

/// Versioned, explicit metadata persisted alongside a cached asset's payload
/// bytes. This — never filesystem `atime` — is authoritative for LRU
/// ordering, quota accounting, and read-time integrity validation.
struct AssetCacheMetadata: Codable, Sendable, Equatable {
    /// Bumped whenever this schema changes; a mismatched version is treated
    /// as a corrupt entry and quarantined rather than partially decoded.
    let schemaVersion: Int
    /// The disk cache key this metadata belongs to, re-checked on read
    /// against the filename it was loaded from.
    let cacheKeyHex: String
    let contentType: String
    let encodedByteCount: Int
    let width: Int
    let height: Int
    /// Hex-encoded SHA-256 of the payload bytes, re-verified on every read.
    let payloadSHA256Hex: String
    let etag: String?
    let lastModified: String?
    /// The exact request URL that produced this payload (one of the
    /// candidates ``AssetLocator`` resolved). Revalidation conditionally
    /// re-requests this same URL rather than re-walking the candidate
    /// chain, so a stale `ETag`/`Last-Modified` pair is never paired with a
    /// different candidate's resource.
    let resolvedURLString: String
    let insertedAt: Date
    /// An actor-issued, monotonically increasing LRU ordering value —
    /// never a wall-clock `Date`. Each cache layer that holds its own copy
    /// of this metadata (``AssetMemoryCache``, ``AssetDiskCache``) stamps
    /// *its own* fresh value here whenever it touches an entry
    /// (`get`/`set`/`touch`), overwriting whatever value the caller
    /// supplied; the value is therefore authoritative only within
    /// whichever single cache layer most recently stamped it, never
    /// compared across layers. This sidesteps the two real defects a
    /// wall-clock `Date` has for this purpose: `Date()`'s resolution can
    /// tie under real concurrent/rapid access (an `ISO8601` string
    /// encoding, in particular, drops sub-second precision entirely,
    /// making same-second ties routine rather than rare), and a wall-clock
    /// step backward (e.g. an NTP correction) can misorder LRU eviction
    /// relative to the true access order. A plain actor-issued integer
    /// sequence cannot regress and, encoded as a fixed-width decimal
    /// string (never a JSON number, whose `Double`-based round-trip loses
    /// precision beyond 2^53), round-trips exactly for the entire `Int`
    /// range this platform supports. See
    /// ``AssetAccessSequence``'s own doc comment for why the encoding is
    /// fixed-width.
    var accessSequence: AssetAccessSequence

    /// The durable, cross-instance/cross-process clear epoch (see
    /// `AssetCacheService+Epoch.swift`'s
    /// ``AssetCacheService/CacheToken/durableClearEpoch``) and this key's
    /// own durable disk write generation (see
    /// ``AssetDiskCache/beginIssuance(for:)``) that were current at the
    /// moment this exact payload's provenance was most recently durably
    /// confirmed fresh from origin — a genuine full publish, a successful
    /// conditional revalidation whose response body is these exact bytes,
    /// **or** a `304 Not Modified` conditional revalidation that
    /// confirmed these already-cached bytes are still current. Advanced
    /// by any of the three (never by a plain metadata-only
    /// ``AssetCacheMetadata/accessSequence`` bump with no accompanying
    /// revalidation at all — an ordinary cache *read* never touches
    /// these fields).
    ///
    /// **A `304` legitimately advances `authorityIDAtPublication`,
    /// even though the payload bytes themselves are unchanged.** A prior
    /// revision left both fields frozen at their *original* full-publish
    /// values across every subsequent `304`, on the theory that they are
    /// this entry's permanent, immutable provenance stamp "for as long as
    /// its payload bytes remain unchanged" — but
    /// ``AssetDiskCache/touch(_:metadata:token:)`` (the disk write a
    /// `304` performs) always durably commits the *revalidating*
    /// operation's own freshly issued identifier as this key's new disk
    /// applied disposition (``AssetDiskCache/commitPublicationLocked(for:token:contentHash:)``),
    /// regardless of what this metadata's own fields say. Leaving this
    /// field frozen therefore let it silently drift out of sync with the
    /// disk's own applied disposition after the very first `304`: a
    /// *third*, subsequent revalidation attempt reads this frozen,
    /// now-stale field back as its own historical stamp and passes it to
    /// `AssetDiskCache.beginRevalidationIssuance`
    /// as `expectedAuthorityID` — which compares it against the disk's
    /// *current* applied identifier (already advanced by the second `304`)
    /// and always finds a mismatch, permanently degrading every
    /// subsequent revalidation attempt for this key into an uncached
    /// full re-fetch the instant a single `304` has ever landed. Advancing
    /// this field in lockstep with every successful `304` (see
    /// ``AssetCacheService/RevalidationCoalescing/performRevalidation(_:)``'s
    /// `.notModified` case) keeps it exactly synchronized with the disk's
    /// own applied identifier, so this stays a correct — not merely a
    /// historical — provenance stamp for every subsequent revalidation.
    /// ``clearEpochAtPublication`` is left unchanged by a `304`: the
    /// operation performing it already had its own durable clear epoch
    /// re-verified unchanged (via ``AssetCacheService/isAuthoritative(_:for:)``)
    /// immediately before the disk write that would persist this value,
    /// so it is, by construction, already identical to the value that
    /// would be written either way.
    ///
    /// This is what actually closes a review finding: a disk (or memory)
    /// hit's own authority must never be re-derived from whatever epoch/
    /// identifier happens to be *current* at the moment the hit is read —
    /// doing so lets bytes published under an old, already-superseded
    /// epoch be silently "relaundered" with a fresh-looking stamp the
    /// instant they are merely read back, entirely independent of
    /// whether a cross-instance/cross-process clear (or a newer write
    /// for this exact key) happened in between. Every revalidation path
    /// instead validates these two fields — this entry's own historical
    /// stamp — against a freshly re-read *current* value, atomically
    /// under one disk-cache lock hold, alongside reserving that
    /// operation's own fresh authority identifier (`beginRevalidationIssuance`);
    /// a mismatch fails closed (falls through to a full, uncached fetch)
    /// rather than ever revalidating bytes whose own provenance no
    /// longer matches durable reality. This historical stamp is
    /// deliberately never threaded through *verbatim* as the operation's
    /// own token authority: doing so would make that token's identifier
    /// indistinguishable, to ``AssetDiskCache/removeIfApplied(_:token:)``'s
    /// exact-match cancellation-retraction contract, from "this exact
    /// operation's own mutation is what is currently applied" even when
    /// this operation itself never applied anything.
    let clearEpochAtPublication: Int
    var authorityIDAtPublication: AuthorityID

    /// Bumped to `5` when ``authorityIDAtPublication`` replaced the
    /// predecessor `writeGenerationAtPublication: Int` field (see
    /// ``AuthorityID``). Relying on the incidental `Codable` decode
    /// failure that a renamed/retyped key happens to produce would make
    /// rejection of an old sidecar an accident of the encoding rather
    /// than an explicit, version-driven decision: every read path
    /// (``AssetDiskCache/get(_:)``, `AssetDiskCache+Recovery.swift`,
    /// `AssetDiskCache+SidecarEntries.swift`) already gates on
    /// `schemaVersion == currentSchemaVersion` *before* any field is
    /// trusted, so bumping the version is what actually makes a
    /// schema-4 sidecar quarantined-as-corrupt by contract.
    static let currentSchemaVersion = 5

    init(
        cacheKeyHex: String,
        contentType: String,
        encodedByteCount: Int,
        width: Int,
        height: Int,
        payloadSHA256Hex: String,
        etag: String?,
        lastModified: String?,
        resolvedURLString: String,
        insertedAt: Date,
        accessSequence: AssetAccessSequence,
        clearEpochAtPublication: Int = 0,
        authorityIDAtPublication: AuthorityID = .pristine
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.cacheKeyHex = cacheKeyHex
        self.contentType = contentType
        self.encodedByteCount = encodedByteCount
        self.width = width
        self.height = height
        self.payloadSHA256Hex = payloadSHA256Hex
        self.etag = etag
        self.lastModified = lastModified
        self.resolvedURLString = resolvedURLString
        self.insertedAt = insertedAt
        self.accessSequence = accessSequence
        self.clearEpochAtPublication = clearEpochAtPublication
        self.authorityIDAtPublication = authorityIDAtPublication
    }

    /// This metadata value's own real serialized-JSON byte count — the
    /// per-entry *overhead* a ``CachedAsset`` bills against the
    /// *in-memory* cache's quota in addition to its actual payload bytes
    /// (see ``CachedAsset/accountedByteCount``, which is the authoritative
    /// total and intentionally measures `payload.count` directly rather
    /// than trusting this value's own ``encodedByteCount`` field, since
    /// that field is merely what this metadata *declares* the payload size
    /// to be, not a guarantee).
    ///
    /// Measuring the actual encoded size — rather than a fixed constant —
    /// matters because ``resolvedURLString`` (and, to a lesser extent,
    /// ``etag``/``lastModified``) has no fixed upper bound: a fixed
    /// estimate could be exceeded by a long URL, silently under-billing the
    /// true bytes counted against the configured memory budget and
    /// undermining the "bounded memory" guarantee.
    ///
    /// ``AssetDiskCache`` independently measures its own on-disk JSON
    /// sidecar file's real byte count for the same reason (its
    /// ``AssetDiskCache/Entry/metadataBytes`` is the exact `Data.count` of
    /// the sidecar bytes already read back from disk while decoding
    /// `metadata` — not a re-encode through any `JSONEncoder` at all —
    /// since the two accounting paths measure genuinely distinct things:
    /// an in-memory estimate of what *would* be written here, vs. what was
    /// *actually* written there, and this type must not depend on
    /// ``AssetDiskCache``'s internals).
    var metadataOverheadBytes: Int {
        let measuredMetadataBytes = (try? Self.makeEncoderForAccounting().encode(self))?.count
        return measuredMetadataBytes ?? Self.estimatedMetadataOverheadBytes
    }

    /// A fallback only: used if encoding this `Codable` value ever somehow
    /// fails, which it should not for a struct composed only of strings,
    /// ints, and dates. Chosen so that an otherwise-impossible encoding
    /// failure fails toward *over*-counting metadata size rather than
    /// crashing or silently letting an entry bill zero metadata bytes.
    static let estimatedMetadataOverheadBytes = 512

    /// A dedicated encoder configuration used only to measure this value's
    /// serialized byte count for in-memory quota accounting — `metadata`
    /// is never actually persisted through this encoder; that is
    /// ``AssetDiskCache``'s own responsibility, and its accounting instead
    /// measures the exact bytes it already wrote/read on disk (see
    /// ``metadataOverheadBytes`` above for the distinction).
    ///
    /// Returns a fresh instance per call, rather than a shared singleton,
    /// since `JSONEncoder` is not documented as thread-safe for concurrent
    /// `encode` calls: `metadataOverheadBytes` above is a plain (non-actor-
    /// isolated) computed property that could otherwise be evaluated
    /// concurrently — e.g. from parallel tests, or multiple in-flight
    /// ``CachedAsset`` constructions — and race on one shared encoder's
    /// internal state. Constructing one is cheap (only setting a date
    /// strategy), so this costs nothing meaningful per call.
    private static func makeEncoderForAccounting() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
