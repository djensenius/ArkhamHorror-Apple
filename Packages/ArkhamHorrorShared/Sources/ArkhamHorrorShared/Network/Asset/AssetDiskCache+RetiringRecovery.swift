import Foundation

/// Durable recovery of interrupted phase-two retractions.
extension AssetDiskCache {
    /// Startup reconciliation reports an explicit write gate rather than
    /// aborting root authority initialization. This keeps `removeAll()`
    /// available to clear a corrupt or over-cap root while every
    /// subsequent issuance retries and surfaces the unresolved state.
    func startupRetiringReconciliationFailureLocked() -> AssetError? {
        do {
            let names = try directoryAccess.listNames()
            guard names.count <= limits.maxAccountableDirectoryEntryCount else {
                return .cachePersistenceFailed(
                    "Too many cache entries to reconcile orphaned retractions"
                )
            }
            try reconcileOrphanedRetiringAuthoritiesLocked(names: names)
            return nil
        } catch let error as AssetError {
            return error
        } catch {
            return .cachePersistenceFailed(String(describing: error))
        }
    }

    /// Reconciles every orphaned `.retiring` authority record visible in
    /// one bounded directory listing. A live owner is preserved; an
    /// ownerless or demonstrably dead owner cannot lawfully publish, so
    /// phase two is completed under this same root lock.
    func reconcileOrphanedRetiringAuthoritiesLocked() throws {
        let names = try directoryAccess.listNames()
        guard names.count <= limits.maxAccountableDirectoryEntryCount else {
            throw AssetError.cachePersistenceFailed(
                "Too many cache entries to reconcile orphaned retractions"
            )
        }
        try reconcileOrphanedRetiringAuthoritiesLocked(names: names)
    }

    /// The quota counterpart, which reuses the listing it already owns.
    /// Any failure is propagated to the caller so it can fail closed
    /// rather than treating an unresolved retirement as permanently live.
    func reconcileOrphanedRetiringAuthoritiesLocked(names: [String]) throws {
        for name in names where name.hasSuffix(Self.authorityRecordFilenameSuffix) {
            guard let record = validatedAuthorityRecordLocked(name: name) else { continue }
            guard record.disposition.kind == .retiring else { continue }
            if let ownerID = record.openIssuanceOwnerID {
                guard let ownerIsLive = secureDirectory.isIssuanceOwnerLive(ownerID) else {
                    throw AssetError.cachePersistenceFailed(
                        "Retiring authority owner could not be verified"
                    )
                }
                guard !ownerIsLive else { continue }
            }
            let keyHash = String(name.dropLast(Self.authorityRecordFilenameSuffix.count))
            guard Self.isValidContentHash(keyHash) else { continue }
            _ = try completeRetractionLocked(
                AssetCacheKey(digestHex: keyHash),
                authorityID: record.disposition.authorityID,
                settlingOrphanedIssuance: true
            )
        }
    }
}
