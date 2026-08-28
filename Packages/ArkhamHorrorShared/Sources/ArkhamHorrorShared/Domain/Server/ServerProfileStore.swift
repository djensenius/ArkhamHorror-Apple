import Foundation

/// Errors produced when reading from or writing to a ``ServerProfileStore``.
enum ServerProfileStoreError: Error, Equatable, Sendable {
    /// Persisted data for the given key exists but could not be decoded.
    ///
    /// The raw bytes are preserved; callers must decide whether to erase or
    /// migrate. Silent erasure is intentionally avoided.
    case corruptData(key: String)
    /// A profile list contains more than one entry with the same ``ServerProfile/id``.
    ///
    /// Thrown by ``ServerProfileStore/saveProfiles(_:)`` when the caller supplies a
    /// list with duplicate identifiers. Selection by UUID would be ambiguous.
    case duplicateProfileIDs
}

/// Read/write access to the list of saved server profiles and the selected profile identity.
///
/// Implementations must be ``Sendable`` and safe to call from any concurrency context.
/// Credentials and authentication tokens must never be stored here.
protocol ServerProfileStore: Sendable {
    /// Loads all saved profiles.
    ///
    /// - Returns: The saved profile list, or an empty array when nothing has been saved.
    /// - Throws: ``ServerProfileStoreError/corruptData(key:)`` when persisted data exists
    ///   but cannot be decoded as `[ServerProfile]`.
    func loadProfiles() throws -> [ServerProfile]

    /// Saves the complete profile list, replacing any prior value.
    func saveProfiles(_ profiles: [ServerProfile]) throws

    /// Returns the identifier of the currently selected profile, or `nil` when none
    /// has been selected.
    ///
    /// - Throws: ``ServerProfileStoreError/corruptData(key:)`` when a value is present
    ///   but is not a valid UUID string.
    func loadSelectedProfileID() throws -> UUID?

    /// Saves the currently selected profile identifier, or clears the selection when
    /// `nil` is passed.
    func saveSelectedProfileID(_ id: UUID?) throws
}
