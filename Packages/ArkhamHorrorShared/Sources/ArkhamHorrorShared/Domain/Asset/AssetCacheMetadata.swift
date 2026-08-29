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

    /// Total bytes this entry counts against the disk quota: payload plus a
    /// conservative estimate of this metadata's own serialized size.
    var accountedByteCount: Int {
        encodedByteCount + Self.estimatedMetadataOverheadBytes
    }

    /// A fixed, conservative estimate rather than re-serializing on every
    /// accounting pass; real serialized size is a few hundred bytes at most.
    static let estimatedMetadataOverheadBytes = 512
}
