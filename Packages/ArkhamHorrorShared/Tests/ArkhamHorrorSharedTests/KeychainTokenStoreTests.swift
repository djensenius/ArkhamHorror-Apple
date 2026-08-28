@testable import ArkhamHorrorShared
import Foundation
import Testing

// MARK: - Test doubles

/// An in-memory ``KeychainClient`` that mimics `SecItem*` add/update/delete/copy
/// semantics without touching the real Keychain. Keyed by service + account so the
/// tests can assert per-profile isolation.
private final class InMemoryKeychainClient: KeychainClient, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    private func key(_ query: [String: Any]) -> String {
        let service = query[kSecAttrService as String] as? String ?? ""
        let account = query[kSecAttrAccount as String] as? String ?? ""
        return "\(service)\u{0}\(account)"
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        let key = key(attributes)
        guard storage[key] == nil else { return errSecDuplicateItem }
        guard let data = attributes[kSecValueData as String] as? Data else {
            return errSecParam
        }
        storage[key] = data
        return errSecSuccess
    }

    func update(_ query: [String: Any], with attributes: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        let key = key(query)
        guard storage[key] != nil else { return errSecItemNotFound }
        guard let data = attributes[kSecValueData as String] as? Data else {
            return errSecParam
        }
        storage[key] = data
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        let key = key(query)
        guard storage[key] != nil else { return errSecItemNotFound }
        storage[key] = nil
        return errSecSuccess
    }

    func copyData(matching query: [String: Any]) -> (status: OSStatus, data: Data?) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = storage[key(query)] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }

    /// Directly seeds a raw value, bypassing the store, for corruption tests.
    func seed(_ data: Data, service: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        storage["\(service)\u{0}\(account)"] = data
    }
}

/// A client that returns a fixed non-success status for every mutating and read call.
private struct FixedStatusKeychainClient: KeychainClient {
    let status: OSStatus

    func add(_: [String: Any]) -> OSStatus {
        status
    }

    func update(_: [String: Any], with _: [String: Any]) -> OSStatus {
        status
    }

    func delete(_: [String: Any]) -> OSStatus {
        status
    }

    func copyData(matching _: [String: Any]) -> (status: OSStatus, data: Data?) {
        (status, nil)
    }
}

/// A client that reproduces the duplicate-item race: the first update reports
/// not-found, the following add reports a duplicate, and the retry update succeeds.
private final class RacingKeychainClient: KeychainClient, @unchecked Sendable {
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
}

// MARK: - Tests

@Suite("KeychainTokenStore")
struct KeychainTokenStoreTests {
    private let profileA = ServerProfile.hosted.id
    private let profileB = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func makeStore(
        _ client: some KeychainClient,
        service: String = "test.arkhamhorror.tokens"
    ) -> KeychainTokenStore {
        KeychainTokenStore(service: service, client: client)
    }

    // MARK: - Add / read

    @Test("Saving then reading returns the stored token")
    func saveThenRead() async throws {
        let store = makeStore(InMemoryKeychainClient())
        try await store.save("token-a", for: profileA)
        let read = try await store.token(for: profileA)
        #expect(read == "token-a")
    }

    @Test("Reading an unknown profile returns nil (item-not-found handled distinctly)")
    func readMissingReturnsNil() async throws {
        let store = makeStore(InMemoryKeychainClient())
        #expect(try await store.token(for: profileA) == nil)
    }

    // MARK: - Update

    @Test("Saving twice updates the existing item in place")
    func saveOverwrites() async throws {
        let store = makeStore(InMemoryKeychainClient())
        try await store.save("first", for: profileA)
        try await store.save("second", for: profileA)
        #expect(try await store.token(for: profileA) == "second")
    }

    // MARK: - Delete

    @Test("Deleting removes the stored token")
    func deleteRemoves() async throws {
        let store = makeStore(InMemoryKeychainClient())
        try await store.save("token-a", for: profileA)
        try await store.deleteToken(for: profileA)
        #expect(try await store.token(for: profileA) == nil)
    }

    @Test("Deleting an absent token is not an error")
    func deleteMissingSucceeds() async throws {
        let store = makeStore(InMemoryKeychainClient())
        await #expect(throws: Never.self) {
            try await store.deleteToken(for: profileA)
        }
    }

    // MARK: - Profile isolation

    @Test("Tokens are isolated per profile UUID")
    func profileIsolation() async throws {
        let store = makeStore(InMemoryKeychainClient())
        try await store.save("token-a", for: profileA)
        try await store.save("token-b", for: profileB)
        #expect(try await store.token(for: profileA) == "token-a")
        #expect(try await store.token(for: profileB) == "token-b")

        try await store.deleteToken(for: profileA)
        #expect(try await store.token(for: profileA) == nil)
        #expect(try await store.token(for: profileB) == "token-b")
    }

    // MARK: - Empty / whitespace tokens

    @Test("Saving an empty or whitespace-only token throws emptyToken")
    func emptyTokenRejected() async {
        let store = makeStore(InMemoryKeychainClient())
        await #expect(throws: KeychainError.emptyToken) {
            try await store.save("", for: profileA)
        }
        await #expect(throws: KeychainError.emptyToken) {
            try await store.save("   \n", for: profileA)
        }
    }

    @Test("A stored whitespace-only value is not accepted as a valid credential")
    func whitespaceStoredValueNotAccepted() async throws {
        let client = InMemoryKeychainClient()
        let service = "test.arkhamhorror.tokens"
        client.seed(Data("   ".utf8), service: service, account: profileA.uuidString)
        let store = makeStore(client, service: service)
        #expect(try await store.token(for: profileA) == nil)
    }

    // MARK: - Duplicate-item race

    @Test("A duplicate-item race during add is resolved by retrying update")
    func duplicateItemRaceResolved() async throws {
        let client = RacingKeychainClient()
        let store = makeStore(client)
        try await store.save("token-a", for: profileA)
        #expect(client.updateCalls == 2)
        #expect(client.addCalls == 1)
    }

    // MARK: - Error mapping

    @Test("An unhandled read status maps to unhandledStatus")
    func readErrorMapping() async {
        let store = makeStore(FixedStatusKeychainClient(status: errSecInteractionNotAllowed))
        await #expect(throws: KeychainError.unhandledStatus(errSecInteractionNotAllowed)) {
            _ = try await store.token(for: profileA)
        }
    }

    @Test("An unhandled update status maps to unhandledStatus")
    func saveErrorMapping() async {
        let store = makeStore(FixedStatusKeychainClient(status: errSecAuthFailed))
        await #expect(throws: KeychainError.unhandledStatus(errSecAuthFailed)) {
            try await store.save("token-a", for: profileA)
        }
    }

    @Test("An unhandled delete status maps to unhandledStatus")
    func deleteErrorMapping() async {
        let store = makeStore(FixedStatusKeychainClient(status: errSecAuthFailed))
        await #expect(throws: KeychainError.unhandledStatus(errSecAuthFailed)) {
            try await store.deleteToken(for: profileA)
        }
    }

    @Test("Corrupt non-UTF8 stored bytes map to unexpectedData")
    func corruptDataMapping() async throws {
        let client = InMemoryKeychainClient()
        let service = "test.arkhamhorror.tokens"
        client.seed(Data([0xFF, 0xFE, 0xFD]), service: service, account: profileA.uuidString)
        let store = makeStore(client, service: service)
        await #expect(throws: KeychainError.unexpectedData) {
            _ = try await store.token(for: profileA)
        }
    }

    // MARK: - No secret leakage

    @Test("Thrown keychain errors never contain the token value")
    func errorsDoNotLeakToken() async {
        let secret = "super-secret-token-value"
        let store = makeStore(FixedStatusKeychainClient(status: errSecAuthFailed))
        do {
            try await store.save(secret, for: profileA)
            Issue.record("Expected save to throw")
        } catch {
            #expect(!String(describing: error).contains(secret))
            #expect(!String(reflecting: error).contains(secret))
        }
    }
}
