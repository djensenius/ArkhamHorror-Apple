@testable import ArkhamHorrorShared
import Foundation
import Security
import Testing

// MARK: - Tests

@Suite("KeychainTokenCleanupPendingStore")
struct KeychainTokenCleanupPendingStoreTests {
    let profileA = ServerProfile.hosted.id
    let profileB = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    /// A UUID whose canonical spelling actually contains hex letters (`A`–`F`), unlike
    /// `profileA`/`profileB` above, so a lower/mixed-case variant of it is a genuinely
    /// different raw string rather than an accidental no-op transform.
    let profileWithLetters = UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890")!

    func makeStore(
        _ client: some KeychainClient,
        service: String = "test.arkhamhorror.cleanup-pending"
    ) -> KeychainTokenCleanupPendingStore {
        KeychainTokenCleanupPendingStore(service: service, client: client)
    }

    // MARK: - Mark / query

    @Test("Marking a profile pending is reflected in pendingProfileIDs")
    func markPendingIsReflected() throws {
        let store = makeStore(InMemoryEnumeratingKeychainClient())
        try store.markPending(profileA)
        #expect(try store.pendingProfileIDs() == [profileA])
    }

    @Test("Marking the same profile twice is idempotent")
    func markPendingTwiceIsIdempotent() throws {
        let store = makeStore(InMemoryEnumeratingKeychainClient())
        try store.markPending(profileA)
        try store.markPending(profileA)
        #expect(try store.pendingProfileIDs() == [profileA])
    }

    @Test("Multiple profiles can be pending simultaneously, isolated by account")
    func multipleProfilesPendingSimultaneously() throws {
        let store = makeStore(InMemoryEnumeratingKeychainClient())
        try store.markPending(profileA)
        try store.markPending(profileB)
        #expect(try store.pendingProfileIDs() == [profileA, profileB])
    }

    @Test("An empty store reports no pending profiles (errSecItemNotFound is empty, not an error)")
    func emptyStoreReportsNoPending() throws {
        let store = makeStore(InMemoryEnumeratingKeychainClient())
        #expect(try store.pendingProfileIDs().isEmpty)
    }

    // MARK: - Clear

    @Test("Clearing a pending profile removes it")
    func clearPendingRemoves() throws {
        let store = makeStore(InMemoryEnumeratingKeychainClient())
        try store.markPending(profileA)
        try store.clearPending(profileA)
        #expect(try store.pendingProfileIDs().isEmpty)
    }

    @Test("Clearing a profile that was never pending is not an error")
    func clearMissingSucceeds() {
        let store = makeStore(InMemoryEnumeratingKeychainClient())
        #expect(throws: Never.self) {
            try store.clearPending(profileA)
        }
    }

    @Test("Clearing one profile does not disturb another pending profile")
    func clearingOneProfilePreservesAnother() throws {
        let store = makeStore(InMemoryEnumeratingKeychainClient())
        try store.markPending(profileA)
        try store.markPending(profileB)
        try store.clearPending(profileA)
        #expect(try store.pendingProfileIDs() == [profileB])
    }

    // MARK: - clearAll

    @Test("clearAll removes every pending marker")
    func clearAllRemovesEveryMarker() throws {
        let store = makeStore(InMemoryEnumeratingKeychainClient())
        try store.markPending(profileA)
        try store.markPending(profileB)
        try store.clearAll()
        #expect(try store.pendingProfileIDs().isEmpty)
    }

    @Test("clearAll on an empty store is not an error")
    func clearAllOnEmptyStoreSucceeds() {
        let store = makeStore(InMemoryEnumeratingKeychainClient())
        #expect(throws: Never.self) {
            try store.clearAll()
        }
    }

    // MARK: - Service isolation from the token store (and between tombstone stores)

    @Test("This store's service is entirely distinct from KeychainTokenStore's own service")
    func serviceIsDistinctFromTokenStore() {
        #expect(
            KeychainTokenCleanupPendingStore.defaultService != KeychainTokenStore.defaultService
        )
    }

    @Test("clearAll never deletes another service's markers, even on the same client")
    func clearAllDoesNotCrossServices() throws {
        let client = InMemoryEnumeratingKeychainClient()
        let storeA = makeStore(client, service: "test.arkhamhorror.cleanup-pending.a")
        let storeB = makeStore(client, service: "test.arkhamhorror.cleanup-pending.b")
        try storeA.markPending(profileA)
        try storeB.markPending(profileA)

        try storeA.clearAll()

        #expect(try storeA.pendingProfileIDs().isEmpty)
        #expect(try storeB.pendingProfileIDs() == [profileA])
    }

    @Test("A marker under the cleanup-pending service is invisible to KeychainTokenStore")
    func markerIsInvisibleToTokenStore() async throws {
        let client = InMemoryEnumeratingKeychainClient()
        let cleanupStore = makeStore(client, service: "test.arkhamhorror.cleanup-pending")
        let tokenStore = KeychainTokenStore(service: "test.arkhamhorror.tokens", client: client)
        // Marking `profileA` pending writes only under the cleanup-pending service; a
        // token read for the very same profile ID, scoped to the token store's own
        // (distinct) service, must find nothing — proving the two namespaces never
        // collide even when sharing one underlying client/keychain.
        try cleanupStore.markPending(profileA)
        let token = try await tokenStore.token(for: profileA)
        #expect(token == nil)
    }

    // MARK: - Error mapping

    @Test("An unhandled markPending status maps to unhandledStatus")
    func markPendingErrorMapping() {
        let store = makeStore(CleanupPendingFixedStatusKeychainClient(status: errSecAuthFailed))
        #expect(throws: TokenCleanupPendingStoreError.unhandledStatus(errSecAuthFailed)) {
            try store.markPending(profileA)
        }
    }

    @Test("An unhandled clearPending status maps to unhandledStatus")
    func clearPendingErrorMapping() {
        let store = makeStore(CleanupPendingFixedStatusKeychainClient(status: errSecAuthFailed))
        #expect(throws: TokenCleanupPendingStoreError.unhandledStatus(errSecAuthFailed)) {
            try store.clearPending(profileA)
        }
    }

    @Test("An unhandled clearAll status maps to unhandledStatus")
    func clearAllErrorMapping() {
        let store = makeStore(CleanupPendingFixedStatusKeychainClient(status: errSecAuthFailed))
        #expect(throws: TokenCleanupPendingStoreError.unhandledStatus(errSecAuthFailed)) {
            try store.clearAll()
        }
    }

    @Test("An unhandled pendingProfileIDs query status maps to unhandledStatus")
    func queryErrorMapping() {
        let store = makeStore(
            CleanupPendingFixedStatusKeychainClient(status: errSecInteractionNotAllowed)
        )
        #expect(
            throws: TokenCleanupPendingStoreError.unhandledStatus(errSecInteractionNotAllowed)
        ) {
            _ = try store.pendingProfileIDs()
        }
    }

    @Test("A returned account that is not a valid profile UUID is reported as corrupt data")
    func corruptAccountReportedAsCorruptData() {
        let store = makeStore(CorruptAccountKeychainClient())
        #expect(throws: TokenCleanupPendingStoreError.corruptData) {
            _ = try store.pendingProfileIDs()
        }
    }

    // MARK: - Account-spelling canonicalization

    // See `KeychainTokenCleanupPendingStoreAccountValidationTests.swift` for coverage
    // of non-canonical account spellings (lower/mixed-case, braced, whitespace-padded)
    // — split out purely to stay within the type-body-length lint limit.

    // MARK: - Duplicate-item race

    @Test("A duplicate-item race during markPending's add is resolved by retrying update")
    func duplicateItemRaceResolved() throws {
        final class RacingClient: KeychainClient, @unchecked Sendable {
            private let lock = NSLock()
            private(set) var updateCalls = 0
            private(set) var addCalls = 0

            func add(_: [String: Any]) -> OSStatus {
                lock.lock()
                defer { lock.unlock() }
                addCalls += 1
                return errSecDuplicateItem
            }

            func update(_: [String: Any], with _: [String: Any]) -> OSStatus {
                lock.lock()
                defer { lock.unlock() }
                updateCalls += 1
                return updateCalls == 1 ? errSecItemNotFound : errSecSuccess
            }

            func delete(_: [String: Any]) -> OSStatus {
                errSecSuccess
            }

            func copyData(matching _: [String: Any]) -> (status: OSStatus, data: Data?) {
                (errSecItemNotFound, nil)
            }

            func copyMatchingAccounts(
                matching _: [String: Any]
            ) -> (status: OSStatus, accounts: [String]?) {
                (errSecItemNotFound, nil)
            }
        }
        let client = RacingClient()
        let store = makeStore(client)
        try store.markPending(profileA)
        #expect(client.updateCalls == 2)
        #expect(client.addCalls == 1)
    }

    // MARK: - No secret leakage

    @Test("Thrown cleanup-pending-store errors never contain a profile ID or marker byte")
    func errorsDoNotLeakProfileIdentity() {
        let store = makeStore(CleanupPendingFixedStatusKeychainClient(status: errSecAuthFailed))
        do {
            try store.markPending(profileA)
            Issue.record("Expected markPending to throw")
        } catch {
            #expect(!String(describing: error).contains(profileA.uuidString))
        }
    }

    // MARK: - Query shape (accessibility class / attributes)

    @Test("markPending's add sets the after-first-unlock-this-device-only accessibility class")
    func addSetsExpectedAccessibilityClass() throws {
        final class CapturingClient: KeychainClient, @unchecked Sendable {
            private(set) var addedAttributes: [String: Any] = [:]
            func add(_ attributes: [String: Any]) -> OSStatus {
                addedAttributes = attributes
                return errSecSuccess
            }

            func update(_: [String: Any], with _: [String: Any]) -> OSStatus {
                errSecItemNotFound
            }

            func delete(_: [String: Any]) -> OSStatus {
                errSecSuccess
            }

            func copyData(matching _: [String: Any]) -> (status: OSStatus, data: Data?) {
                (errSecItemNotFound, nil)
            }

            func copyMatchingAccounts(
                matching _: [String: Any]
            ) -> (status: OSStatus, accounts: [String]?) {
                (errSecItemNotFound, nil)
            }
        }
        let client = CapturingClient()
        let store = makeStore(client)
        try store.markPending(profileA)
        let accessible = client.addedAttributes[kSecAttrAccessible as String] as? String
        #expect(accessible == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String))
        #expect(client.addedAttributes[kSecAttrAccount as String] as? String == profileA.uuidString)
        #expect(
            client.addedAttributes[kSecAttrService as String] as? String
                == "test.arkhamhorror.cleanup-pending"
        )
    }

    // MARK: - Production adapter account-parsing (fail-closed)

    @Test(
        """
        SecurityKeychainClient.accounts(fromMatchingItems:) returns every account \
        when all items are well-formed
        """
    )
    func productionAdapterParsesWellFormedAccounts() {
        let items: [[String: Any]] = [
            [kSecAttrAccount as String: profileA.uuidString],
            [kSecAttrAccount as String: profileB.uuidString],
        ]
        let accounts = SecurityKeychainClient.accounts(fromMatchingItems: items)
        #expect(accounts.map(Set.init) == Set([profileA.uuidString, profileB.uuidString]))
    }

    @Test(
        """
        SecurityKeychainClient.accounts(fromMatchingItems:) fails closed (returns nil, \
        never silently drops) when any item lacks a string kSecAttrAccount, rather than \
        undercounting pending tombstones the way `compactMap` would
        """
    )
    func productionAdapterFailsClosedOnMissingAccountAttribute() {
        let missingAccount: [[String: Any]] = [
            [kSecAttrAccount as String: profileA.uuidString],
            [kSecAttrService as String: "test.arkhamhorror.cleanup-pending"],
        ]
        #expect(SecurityKeychainClient.accounts(fromMatchingItems: missingAccount) == nil)

        let nonStringAccount: [[String: Any]] = [
            [kSecAttrAccount as String: 42],
        ]
        #expect(SecurityKeychainClient.accounts(fromMatchingItems: nonStringAccount) == nil)
    }
}
