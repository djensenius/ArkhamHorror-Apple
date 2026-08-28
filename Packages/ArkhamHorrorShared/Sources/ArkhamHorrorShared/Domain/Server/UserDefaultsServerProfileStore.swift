import Foundation

/// A ``ServerProfileStore`` backed by ``UserDefaults``.
///
/// Persists the profile list as JSON-encoded data and the selected profile identity as
/// a UUID string. Two instances backed by different ``UserDefaults`` suites are fully
/// isolated from one another, which makes test storage straightforward:
///
/// ```swift
/// let store = UserDefaultsServerProfileStore(
///     defaults: UserDefaults(suiteName: "com.tests.MyTest")!
/// )
/// ```
///
/// Corrupt persisted data is surfaced as ``ServerProfileStoreError/corruptData(key:)``
/// rather than silently discarded.
/// - Note: `UserDefaults` does not carry a `Sendable` annotation in this SDK version;
///   the `@unchecked Sendable` conformance is safe because `UserDefaults` is
///   documented as thread-safe for `set`/`data(forKey:)`/`string(forKey:)` operations.
struct UserDefaultsServerProfileStore: ServerProfileStore, @unchecked Sendable {
    private enum Keys {
        static let profiles = "ArkhamHorror.serverProfiles"
        static let selectedProfileID = "ArkhamHorror.selectedServerProfileID"
    }

    private let defaults: UserDefaults

    /// Creates a store backed by the given `UserDefaults` suite.
    ///
    /// Pass `.standard` for production use or a named suite for test isolation.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadProfiles() throws -> [ServerProfile] {
        guard let data = defaults.data(forKey: Keys.profiles) else {
            return []
        }
        let profiles: [ServerProfile]
        do {
            profiles = try JSONDecoder().decode([ServerProfile].self, from: data)
        } catch {
            throw ServerProfileStoreError.corruptData(key: Keys.profiles)
        }
        let ids = profiles.map(\.id)
        guard ids.count == Set(ids).count else {
            throw ServerProfileStoreError.corruptData(key: Keys.profiles)
        }
        return profiles
    }

    func saveProfiles(_ profiles: [ServerProfile]) throws {
        let ids = profiles.map(\.id)
        guard ids.count == Set(ids).count else {
            throw ServerProfileStoreError.duplicateProfileIDs
        }
        let data = try JSONEncoder().encode(profiles)
        defaults.set(data, forKey: Keys.profiles)
    }

    func loadSelectedProfileID() throws -> UUID? {
        guard let string = defaults.string(forKey: Keys.selectedProfileID) else {
            return nil
        }
        guard let uuid = UUID(uuidString: string) else {
            throw ServerProfileStoreError.corruptData(key: Keys.selectedProfileID)
        }
        return uuid
    }

    func saveSelectedProfileID(_ id: UUID?) throws {
        if let id {
            defaults.set(id.uuidString, forKey: Keys.selectedProfileID)
        } else {
            defaults.removeObject(forKey: Keys.selectedProfileID)
        }
    }
}
