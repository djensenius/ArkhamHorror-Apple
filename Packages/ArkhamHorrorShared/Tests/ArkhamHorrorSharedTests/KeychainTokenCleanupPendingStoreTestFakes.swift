@testable import ArkhamHorrorShared
import Foundation
import Security

// Test doubles shared by `KeychainTokenCleanupPendingStoreTests`, split into their own
// file to stay within the project's file-length lint limit.

/// An in-memory ``KeychainClient`` that also supports attribute enumeration
/// (``copyMatchingAccounts(matching:)``), so ``KeychainTokenCleanupPendingStore`` can
/// be exercised without touching the real Keychain. Keyed by service + account,
/// exactly like ``KeychainTokenStoreTests``'s own fake, so isolation between two
/// differently-serviced stores sharing one client instance can be asserted directly.
final class InMemoryEnumeratingKeychainClient: KeychainClient, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    private func key(service: String, account: String) -> String {
        "\(service)\u{0}\(account)"
    }

    private func key(_ query: [String: Any]) -> String {
        let service = query[kSecAttrService as String] as? String ?? ""
        let account = query[kSecAttrAccount as String] as? String ?? ""
        return key(service: service, account: account)
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
        guard query[kSecAttrAccount as String] != nil else {
            let service = query[kSecAttrService as String] as? String ?? ""
            let prefix = "\(service)\u{0}"
            let matchingKeys = storage.keys.filter { $0.hasPrefix(prefix) }
            guard !matchingKeys.isEmpty else { return errSecItemNotFound }
            for matchingKey in matchingKeys {
                storage[matchingKey] = nil
            }
            return errSecSuccess
        }
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

    func copyMatchingAccounts(
        matching query: [String: Any]
    ) -> (status: OSStatus, accounts: [String]?) {
        lock.lock()
        defer { lock.unlock() }
        let service = query[kSecAttrService as String] as? String ?? ""
        let prefix = "\(service)\u{0}"
        let accounts = storage.keys
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
        guard !accounts.isEmpty else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, accounts)
    }
}

/// A client that returns a fixed non-success status for every call, used to prove
/// error mapping without any dependency on real Keychain error conditions.
struct CleanupPendingFixedStatusKeychainClient: KeychainClient {
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

    func copyMatchingAccounts(
        matching _: [String: Any]
    ) -> (status: OSStatus, accounts: [String]?) {
        (status, nil)
    }
}

/// A client whose `copyMatchingAccounts` reports success but an unexpected/corrupt
/// shape (a non-UUID account string), to exercise the store's own validation of every
/// returned account identifier.
struct CorruptAccountKeychainClient: KeychainClient {
    func add(_: [String: Any]) -> OSStatus {
        errSecSuccess
    }

    func update(_: [String: Any], with _: [String: Any]) -> OSStatus {
        errSecSuccess
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
        (errSecSuccess, ["not-a-uuid"])
    }
}
