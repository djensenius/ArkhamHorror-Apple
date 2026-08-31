import Foundation

/// Durable-counter persistence helper for ``AssetDiskCache``, split out
/// of `AssetDiskCache+WriteGeneration.swift` purely to stay under this
/// package's file-length limit. The applied-*ticket* commit paths that
/// used to live here (`commitAppliedTicketLocked(_:for:)`/
/// `reserveAndCommitMutationTicketLocked(for:)`/
/// `commitMutationTicketLocked(for:token:)`) have been superseded by
/// ``AssetDiskCache/commitPublicationLocked(for:token:contentHash:)``/
/// ``AssetDiskCache/commitRetractionLocked(for:token:destroy:)`` in
/// `AssetDiskCache+Disposition.swift`, which commit a typed
/// ``AssetDiskCache/KeyDisposition`` rather than a bare ticket integer —
/// see that file's own type-level doc comment for why. Only the
/// low-level fixed-width persistence helper for the (still bare-integer)
/// `.gen` issuance counter remains here.
extension AssetDiskCache {
    func persistTicketLocked(_ value: Int, name: String) throws {
        precondition(value >= 0, "A ticket must never be negative")
        let raw = String(value)
        let padded = String(repeating: "0", count: Self.ticketDigitWidth - raw.count) + raw
        let tempName = name + ".tmp"
        try secureDirectory.writeTempAndFsync(tempName: tempName, data: Data(padded.utf8))
        try secureDirectory.renameAndFsyncDirectory(from: tempName, to: name)
    }
}
