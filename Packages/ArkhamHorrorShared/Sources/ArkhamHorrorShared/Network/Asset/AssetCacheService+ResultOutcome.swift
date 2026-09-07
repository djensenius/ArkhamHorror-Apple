/// A tiny shared helper for both ``AssetCacheService/coalescedFetch(key:cacheKey:candidates:)``
/// and `coalescedRevalidation(cacheKey:url:expectedFormat:existing:preIssuedAuthority:)`,
/// each of which needs the plain success/failure shape of an
/// already-produced `Result` (never its payload) to decide the waiter's
/// final outcome, without caring which specific error case a failure
/// carries.
extension Result {
    var isCacheOperationSuccess: Bool {
        if case .success = self {
            return true
        }
        return false
    }
}
