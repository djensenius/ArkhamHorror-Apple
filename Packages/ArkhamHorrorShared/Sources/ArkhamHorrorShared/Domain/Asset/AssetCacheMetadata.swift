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
    var lastAccessedAt: Date

    static let currentSchemaVersion = 1

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
        lastAccessedAt: Date
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
        self.lastAccessedAt = lastAccessedAt
    }

    /// Total bytes this entry counts against the *in-memory* cache's quota:
    /// payload plus this metadata value's own real serialized-JSON byte
    /// count. Measuring the actual encoded size — rather than a fixed
    /// constant — matters because ``resolvedURLString`` (and, to a lesser
    /// extent, ``etag``/``lastModified``) has no fixed upper bound: a fixed
    /// estimate could be exceeded by a long URL, silently under-billing the
    /// true bytes counted against the configured memory budget and
    /// undermining the "bounded memory" guarantee.
    ///
    /// ``AssetDiskCache`` independently measures its own on-disk JSON
    /// sidecar file's real byte count for the same reason (its measurement
    /// uses a separate, differently-configured `JSONEncoder` instance
    /// private to that file, since the two accounting paths measure
    /// genuinely distinct things — an in-memory estimate here vs. an
    /// actual written file there — and this type must not depend on
    /// ``AssetDiskCache``'s internals).
    var accountedByteCount: Int {
        let measuredMetadataBytes = (try? Self.encoderForAccounting.encode(self))?.count
        return encodedByteCount + (measuredMetadataBytes ?? Self.estimatedMetadataOverheadBytes)
    }

    /// A fallback only: used if encoding this `Codable` value ever somehow
    /// fails, which it should not for a struct composed only of strings,
    /// ints, and dates. Chosen so that an otherwise-impossible encoding
    /// failure fails toward *over*-counting metadata size rather than
    /// crashing or silently letting an entry bill zero metadata bytes.
    static let estimatedMetadataOverheadBytes = 512

    /// A dedicated encoder instance (not shared with ``AssetDiskCache``'s
    /// own file-private encoder) used only to measure this value's
    /// serialized byte count for in-memory quota accounting.
    private static let encoderForAccounting: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
