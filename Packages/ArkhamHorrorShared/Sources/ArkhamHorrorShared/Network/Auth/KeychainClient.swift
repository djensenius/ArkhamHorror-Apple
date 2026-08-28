import Foundation
import Security

/// A narrow, injectable wrapper over the Security framework generic-password C API.
///
/// This abstraction exists so ``KeychainTokenStore`` can be exercised deterministically
/// with an in-memory fake, without touching the real Keychain or the tester's login
/// keychain. The four operations map one-to-one onto `SecItemAdd`, `SecItemUpdate`,
/// `SecItemDelete`, and `SecItemCopyMatching`.
///
/// Query and attribute dictionaries never contain token contents in a form suitable for
/// logging; conformances must not log their arguments.
protocol KeychainClient: Sendable {
    /// Adds a new keychain item. Maps to `SecItemAdd`.
    func add(_ attributes: [String: Any]) -> OSStatus
    /// Updates the attributes of items matching `query`. Maps to `SecItemUpdate`.
    func update(_ query: [String: Any], with attributes: [String: Any]) -> OSStatus
    /// Deletes items matching `query`. Maps to `SecItemDelete`.
    func delete(_ query: [String: Any]) -> OSStatus
    /// Returns the data payload of the single item matching `query`, if any.
    ///
    /// Maps to `SecItemCopyMatching` with `kSecReturnData`. On `errSecSuccess` the
    /// associated data is returned; on any other status the data is `nil`.
    func copyData(matching query: [String: Any]) -> (status: OSStatus, data: Data?)

    /// Returns the `kSecAttrAccount` value of every item matching `query`, without
    /// returning any item's data payload.
    ///
    /// Maps to `SecItemCopyMatching` with `kSecReturnAttributes` and
    /// `kSecMatchLimitAll`, used by ``KeychainTokenCleanupPendingStore`` to enumerate
    /// which profile IDs currently have a pending-cleanup marker — never to read any
    /// token's contents. On `errSecSuccess` every matched item's account string is
    /// returned; if any item lacks a decodable account attribute, a conforming
    /// implementation must fail closed — reporting a non-success status (as
    /// ``SecurityKeychainClient`` does via `errSecDecode`) rather than silently
    /// omitting that item, since the caller treats a missing account as
    /// impossible/corrupt data, not as "absent". On any other status the accounts
    /// are `nil`.
    ///
    /// A default implementation is provided so existing ``KeychainClient``
    /// conformances (production and test doubles) that never enumerate accounts are
    /// not required to implement this; ``SecurityKeychainClient`` and any test double
    /// that does need real enumeration behavior override it.
    func copyMatchingAccounts(
        matching query: [String: Any]
    ) -> (status: OSStatus, accounts: [String]?)
}

extension KeychainClient {
    /// Default: enumeration is unsupported. Only ``SecurityKeychainClient`` and test
    /// doubles that specifically exercise ``KeychainTokenCleanupPendingStore`` need a
    /// real implementation.
    func copyMatchingAccounts(
        matching _: [String: Any]
    ) -> (status: OSStatus, accounts: [String]?) {
        (errSecUnimplemented, nil)
    }
}

/// The production ``KeychainClient`` backed directly by the Security framework.
///
/// Carries no stored state, so it is trivially `Sendable`. Each call bridges its Swift
/// dictionary to a `CFDictionary` and invokes the corresponding `SecItem*` function.
struct SecurityKeychainClient: KeychainClient {
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(_ query: [String: Any], with attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }

    func copyData(matching query: [String: Any]) -> (status: OSStatus, data: Data?) {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }

    func copyMatchingAccounts(
        matching query: [String: Any]
    ) -> (status: OSStatus, accounts: [String]?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return (status, nil) }
        guard let items = result as? [[String: Any]] else {
            // A single-item result (rather than an array) would indicate the query
            // did not actually request `kSecMatchLimitAll`; treat as a caller error
            // rather than guessing at a shape.
            return (errSecParam, nil)
        }
        guard let accounts = Self.accounts(fromMatchingItems: items) else {
            // An item missing (or with a non-string) account attribute is corrupt:
            // silently dropping it via `compactMap` would let `pendingProfileIDs()`
            // undercount pending tombstones, breaking this store's fail-closed
            // contract. Report the whole query as corrupt instead of returning a
            // partial, misleadingly-successful result.
            return (errSecDecode, nil)
        }
        return (errSecSuccess, accounts)
    }

    /// Extracts every item's `kSecAttrAccount` string value from a
    /// `SecItemCopyMatching` attributes-dictionary result, or `nil` if *any* item
    /// lacks a string account attribute — a pure, directly testable helper isolating
    /// ``copyMatchingAccounts(matching:)``'s fail-closed parsing from the Security
    /// framework call itself (which this project's tests never invoke live).
    static func accounts(fromMatchingItems items: [[String: Any]]) -> [String]? {
        var accounts: [String] = []
        accounts.reserveCapacity(items.count)
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else {
                return nil
            }
            accounts.append(account)
        }
        return accounts
    }
}
