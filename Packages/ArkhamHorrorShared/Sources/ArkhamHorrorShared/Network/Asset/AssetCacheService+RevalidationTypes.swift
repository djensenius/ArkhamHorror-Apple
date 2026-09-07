import Foundation

/// Supporting value types for the conditional-revalidation subsystem in
/// `AssetCacheService+Revalidation.swift`. Split into their own file purely
/// to keep that file within this package's `file_length` convention; these
/// remain nested inside the single `AssetCacheService` actor.
extension AssetCacheService {
    /// Identifies a single logical in-flight revalidation: the cache key,
    /// the exact URL it targets, and the validator snapshot
    /// (`etag`/`lastModified`) the request was conditioned on. This — not
    /// `cacheKey` alone — is `inFlightRevalidation`'s dictionary key,
    /// because two overlapping revalidations for the *same* cache key can
    /// legitimately be independent operations (a caller whose view of the
    /// cached entry has since changed, e.g. after another revalidation's
    /// own completion, must never be silently folded into a fetch
    /// conditioned on a validator it no longer holds — see
    /// ``coalescedRevalidation(cacheKey:url:expectedFormat:existing:preIssuedAuthority:)``).
    /// Keying only
    /// by `cacheKey` would let a second, independent fetch's registration
    /// overwrite the first's dictionary entry, orphaning the first
    /// fetch's own waiters (their completion/cancellation lookups by
    /// `fetchID` would silently miss forever, hanging that caller).
    struct RevalidationSlot: Hashable {
        let cacheKey: AssetCacheKey
        let url: URL
        let etag: String?
        let lastModified: String?
    }

    /// Tracks a single shared in-flight revalidation and the
    /// still-registered waiters awaiting it. Mirrors ``InFlightFetch``
    /// (see its doc comment for why a plain, non-`Sendable` value type
    /// living only inside `inFlightRevalidation` is safe here too).
    struct RevalidationFetch {
        let id = UUID()
        let task: Task<CachedAsset, Error>
        /// Mirrors ``InFlightFetch/token``: retained so
        /// ``AssetCacheService/cancelRevalidationWaiter(_:fetchID:waiterID:)``
        /// can retire it the moment the last waiter for this revalidation
        /// cancels.
        let token: CacheToken
        var waiters: [UUID: AssetContinuation] = [:]
    }

    /// Groups every input ``performRevalidation(_:)`` needs into a single
    /// value so the function itself stays within this package's
    /// `function_parameter_count` limit; purely a parameter-passing
    /// convenience with no independent identity or lifecycle of its own.
    struct RevalidationRequest {
        let cacheKey: AssetCacheKey
        let url: URL
        let expectedFormat: AssetFormat
        let existing: CachedAsset
        let etag: String?
        let lastModified: String?
        let token: CacheToken
    }
}
