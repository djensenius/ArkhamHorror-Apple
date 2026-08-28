import Foundation

/// Errors produced when reading from or writing to a ``TokenCleanupPendingStore``.
enum TokenCleanupPendingStoreError: Error, Equatable, Sendable {
    /// Persisted data for the pending-cleanup record exists but could not be decoded.
    case corruptData
}

/// A durable, non-secret record of which server-profile IDs have a token-store
/// cleanup deletion still pending — never token material or fingerprints, only
/// profile identifiers — so a cancellation's (or profile switch's) cleanup delete
/// that has not yet completed is never silently forgotten, even across an
/// ``AppModel`` reconstruction or a full process restart.
///
/// A profile ID is marked pending synchronously, before the delete that will resolve
/// it is even enqueued, and is cleared *only* after that delete actually succeeds or
/// finds nothing to delete (`errSecItemNotFound`) — never merely because an error was
/// surfaced, a retry was pressed, a new auth attempt began, the profile was switched
/// or removed, or the app restarted. See ``AppModel/resolvePendingCleanup(for:)`` and
/// ``AppModel/enqueueCancellationCleanup(for:globalEpoch:)``.
///
/// Implementations must be ``Sendable`` and safe to call from any concurrency context.
protocol TokenCleanupPendingStore: Sendable {
    /// The set of profile IDs with a cleanup deletion still pending.
    func pendingProfileIDs() throws -> Set<UUID>

    /// Durably records that `profileID` has a cleanup deletion pending. Idempotent.
    func markPending(_ profileID: UUID) throws

    /// Durably clears `profileID`'s pending-cleanup record, if any. Idempotent.
    func clearPending(_ profileID: UUID) throws

    /// Durably clears every pending-cleanup record. Used only after a full storage
    /// reset's ``TokenStore/deleteAllTokens()`` has itself already succeeded.
    func clearAll() throws
}

/// A ``TokenCleanupPendingStore`` backed by ``UserDefaults``.
///
/// Persists only profile UUID strings, exactly like
/// ``UserDefaultsServerProfileStore``'s selected-profile identity — never a token, a
/// token fingerprint, or any other secret material.
/// - Note: `UserDefaults` does not carry a `Sendable` annotation in this SDK version;
///   the `@unchecked Sendable` conformance is safe because `UserDefaults` is
///   documented as thread-safe for access.
struct UserDefaultsTokenCleanupPendingStore: TokenCleanupPendingStore, @unchecked Sendable {
    private enum Keys {
        static let pendingProfileIDs = "ArkhamHorror.pendingTokenCleanup"
    }

    private let defaults: UserDefaults

    /// Creates a store backed by the given `UserDefaults` suite.
    ///
    /// Pass `.standard` for production use (the default) or a named/isolated suite for
    /// test isolation.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func pendingProfileIDs() throws -> Set<UUID> {
        guard let storedValue = defaults.object(forKey: Keys.pendingProfileIDs) else {
            return []
        }
        guard let strings = storedValue as? [String] else {
            throw TokenCleanupPendingStoreError.corruptData
        }
        var ids = Set<UUID>()
        for string in strings {
            guard let uuid = UUID(uuidString: string) else {
                throw TokenCleanupPendingStoreError.corruptData
            }
            ids.insert(uuid)
        }
        return ids
    }

    func markPending(_ profileID: UUID) throws {
        var ids = try pendingProfileIDs()
        guard !ids.contains(profileID) else { return }
        ids.insert(profileID)
        write(ids)
    }

    func clearPending(_ profileID: UUID) throws {
        var ids = try pendingProfileIDs()
        guard ids.remove(profileID) != nil else { return }
        write(ids)
    }

    func clearAll() throws {
        defaults.removeObject(forKey: Keys.pendingProfileIDs)
    }

    private func write(_ ids: Set<UUID>) {
        defaults.set(ids.map(\.uuidString), forKey: Keys.pendingProfileIDs)
    }
}
