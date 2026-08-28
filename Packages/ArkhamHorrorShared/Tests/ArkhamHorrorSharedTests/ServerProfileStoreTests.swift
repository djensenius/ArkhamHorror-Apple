@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("ServerProfileStore")
struct ServerProfileStoreTests {
    // MARK: - Helpers

    /// Returns a `UserDefaultsServerProfileStore` backed by a unique ephemeral suite.
    private func isolatedStore() throws -> UserDefaultsServerProfileStore {
        let suite = "com.tests.ServerProfileStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return UserDefaultsServerProfileStore(defaults: defaults)
    }

    private func makeProfile(
        name: String = "Test",
        url: String = "https://example.com"
    ) throws -> ServerProfile {
        try ServerProfile.custom(displayName: name, rawURL: url)
    }

    // MARK: - Empty store

    @Test("Empty store returns an empty profile list")
    func emptyStoreReturnsEmpty() throws {
        let store = try isolatedStore()
        #expect(try store.loadProfiles().isEmpty)
    }

    @Test("Empty store returns nil for the selected profile ID")
    func emptyStoreReturnsNilSelection() throws {
        let store = try isolatedStore()
        #expect(try store.loadSelectedProfileID() == nil)
    }

    // MARK: - Round-trips

    @Test("Profiles saved to the store load back equal and in order")
    func profilesRoundTrip() throws {
        let store = try isolatedStore()
        let profiles = try [
            makeProfile(name: "Server A", url: "https://a.example.com"),
            makeProfile(name: "Server B", url: "http://localhost:8080"),
        ]
        try store.saveProfiles(profiles)
        #expect(try store.loadProfiles() == profiles)
    }

    @Test("Saving an empty list replaces previously stored profiles")
    func saveEmptyClearsProfiles() throws {
        let store = try isolatedStore()
        try store.saveProfiles([makeProfile()])
        try store.saveProfiles([])
        #expect(try store.loadProfiles().isEmpty)
    }

    @Test("Selected profile ID round-trips through the store")
    func selectedIDRoundTrip() throws {
        let store = try isolatedStore()
        let id = UUID()
        try store.saveSelectedProfileID(id)
        #expect(try store.loadSelectedProfileID() == id)
    }

    @Test("Saving nil selected ID clears the stored selection")
    func saveNilClearsSelection() throws {
        let store = try isolatedStore()
        try store.saveSelectedProfileID(UUID())
        try store.saveSelectedProfileID(nil)
        #expect(try store.loadSelectedProfileID() == nil)
    }

    // MARK: - Duplicate ID rejection

    @Test("Saving a profile list with duplicate IDs throws duplicateProfileIDs")
    func saveDuplicateIDsThrows() throws {
        let store = try isolatedStore()
        let sharedID = UUID()
        let profileA = try ServerProfile.custom(
            id: sharedID,
            displayName: "Server A",
            rawURL: "https://a.example.com"
        )
        let profileB = try ServerProfile.custom(
            id: sharedID,
            displayName: "Server B",
            rawURL: "https://b.example.com"
        )
        #expect(throws: ServerProfileStoreError.duplicateProfileIDs) {
            try store.saveProfiles([profileA, profileB])
        }
    }

    @Test("Loading persisted data with duplicate IDs throws corruptData")
    func loadDuplicateIDsThrowsCorruptData() throws {
        let suite = "com.tests.ServerProfileStoreTests.dupIDs.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = UserDefaultsServerProfileStore(defaults: defaults)

        // Manually persist two profiles sharing the same UUID to simulate corruption.
        let sharedID = UUID()
        let json = """
        [
            {
                "id": "\(sharedID.uuidString)",
                "displayName": "Server A",
                "baseURL": "https://a.example.com",
                "kind": "custom"
            },
            {
                "id": "\(sharedID.uuidString)",
                "displayName": "Server B",
                "baseURL": "https://b.example.com",
                "kind": "custom"
            }
        ]
        """
        defaults.set(Data(json.utf8), forKey: "ArkhamHorror.serverProfiles")

        #expect(
            throws: ServerProfileStoreError.corruptData(key: "ArkhamHorror.serverProfiles")
        ) {
            try store.loadProfiles()
        }
    }

    @Test("Selection by ID is stable when the profile list is reordered")
    func selectionStableAfterReorder() throws {
        let store = try isolatedStore()
        let profileA = try makeProfile(name: "Server A", url: "https://a.example.com")
        let profileB = try makeProfile(name: "Server B", url: "https://b.example.com")
        let profileC = try makeProfile(name: "Server C", url: "https://c.example.com")

        try store.saveProfiles([profileA, profileB, profileC])
        try store.saveSelectedProfileID(profileB.id)

        // Reorder the list and re-save without changing the selected ID.
        try store.saveProfiles([profileC, profileA, profileB])

        let selectedID = try store.loadSelectedProfileID()
        #expect(selectedID == profileB.id)
    }

    // MARK: - Corruption

    @Test("Corrupt profiles bytes throw corruptData rather than returning an empty list")
    func corruptProfilesThrow() throws {
        let suite = "com.tests.ServerProfileStoreTests.corrupt.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = UserDefaultsServerProfileStore(defaults: defaults)
        defaults.set(Data("not valid json".utf8), forKey: "ArkhamHorror.serverProfiles")

        #expect(
            throws: ServerProfileStoreError.corruptData(key: "ArkhamHorror.serverProfiles")
        ) {
            try store.loadProfiles()
        }
    }

    @Test("A non-UUID selected ID string throws corruptData rather than returning nil")
    func corruptSelectedIDThrows() throws {
        let suite = "com.tests.ServerProfileStoreTests.corruptID.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = UserDefaultsServerProfileStore(defaults: defaults)
        defaults.set("not-a-uuid", forKey: "ArkhamHorror.selectedServerProfileID")

        #expect(
            throws: ServerProfileStoreError.corruptData(
                key: "ArkhamHorror.selectedServerProfileID"
            )
        ) {
            try store.loadSelectedProfileID()
        }
    }

    // MARK: - Isolation

    @Test("Two stores backed by distinct suites do not share profile data")
    func storeIsolation() throws {
        let storeA = try isolatedStore()
        let storeB = try isolatedStore()
        try storeA.saveProfiles([makeProfile(name: "A")])
        #expect(try storeB.loadProfiles().isEmpty)
    }
}
