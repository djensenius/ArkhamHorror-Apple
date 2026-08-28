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
}
