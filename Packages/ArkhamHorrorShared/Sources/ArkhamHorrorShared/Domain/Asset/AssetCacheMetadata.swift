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
    /// A durable, per-key, monotonically increasing write generation —
    /// the disk-persisted half of the compare-and-swap that gates every
    /// publish/touch/removal, alongside ``AssetCacheService/CacheToken``'s
    /// existing purely in-process issuance ordering. The in-process token
    /// alone cannot detect a stale write racing against a *different*
    /// process's `AssetCacheService`/`AssetDiskCache` instance pointed at
    /// this same directory: two such instances' token/issuance counters
    /// are neither shared nor even meaningfully comparable to one
    /// another. This field closes that gap by persisting the ordering
    /// signal itself, on disk, where every instance/process can read and
    /// compare it: an operation captures the *current* on-disk generation
    /// for its key at issuance (before it ever suspends for network I/O),
    /// and every later write for that key is only accepted if this value
    /// is still exactly what that operation captured — otherwise some
    /// other, more-recently-completed write (from this process or
    /// another) has already superseded it, and this write is a stale
    /// no-op instead. Stamped fresh by ``AssetDiskCache`` itself on every
    /// accepted write, exactly like ``accessSequence`` — never trusted
    /// from whatever value a caller happens to pass in.
    var writeGeneration: Int

    static let currentSchemaVersion = 3

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
        writeGeneration: Int = 0
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
        self.writeGeneration = writeGeneration
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
