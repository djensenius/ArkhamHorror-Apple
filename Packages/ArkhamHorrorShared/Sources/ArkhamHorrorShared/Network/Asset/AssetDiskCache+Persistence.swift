import Foundation

/// Read-time quarantine and atomic metadata persistence helpers for
/// ``AssetDiskCache``, split out of `AssetDiskCache.swift` purely to stay
/// under this package's `file_length` convention.
extension AssetDiskCache {
    /// Removes an entry that has failed integrity validation on read: its
    /// metadata sidecar, and — via
    /// ``cleanupSupersededPayloads(forKeyHash:keeping:)`` — every `.bin`
    /// payload generation on disk for `keyHash`. Best-effort: a read-time
    /// quarantine failure is not distinguished from an ordinary miss (see
    /// ``get(_:)``'s doc comment).
    func quarantine(keyHash: String, metadataName: String) {
        _ = try? secureDirectory.remove(name: metadataName)
        cleanupSupersededPayloads(forKeyHash: keyHash, keeping: nil)
    }

    func persistMetadata(_ metadata: AssetCacheMetadata, name: String) throws {
        let data = try JSONEncoder.assetCache().encode(metadata)
        try secureDirectory.writeTempAndFsync(tempName: name + ".tmp", data: data)
        try secureDirectory.renameAndFsyncDirectory(from: name + ".tmp", to: name)
    }

    /// Exposed so `AssetDiskCache+Recovery.swift` (in the same file-length
    /// budget as this type) can perform its own descriptor-relative
    /// listing/reads/removals through the same verified directory.
    var directoryAccess: SecureCacheDirectory {
        secureDirectory
    }

    /// Exposed so `AssetDiskCache+Recovery.swift` can reconcile this
    /// cache directory's durable, cross-instance/cross-process
    /// access-sequence counter (``SecureCacheDirectory/allocateAccessSequence(atLeastAfter:)``)
    /// with the highest sequence value found among currently valid
    /// persisted entries during startup recovery, so every freshly
    /// allocated value afterward is guaranteed greater than every value
    /// that already exists on disk — see
    /// ``SecureCacheDirectory/floorAccessSequence(atLeast:)``'s own doc
    /// comment for why this full-directory-scan-derived floor is still
    /// needed even with a durable counter file. Best-effort: a failure
    /// here does not abort recovery (each individual write's own
    /// `atLeastAfter` floor, and the durable counter file once it exists,
    /// remain the correctness backstop).
    func reconcileAccessSequenceFloor(_ highestKnownValue: Int?) {
        _ = try? secureDirectory.floorAccessSequence(atLeast: highestKnownValue)
    }
}
