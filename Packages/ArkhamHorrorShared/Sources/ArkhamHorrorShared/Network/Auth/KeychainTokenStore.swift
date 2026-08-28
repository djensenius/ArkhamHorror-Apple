import Foundation
import Security

/// A ``TokenStore`` backed by Security framework generic-password Keychain items.
///
/// Each token is stored as a single generic-password item whose service is a stable,
/// build-wide identifier and whose account is the canonical `UUID` string of the owning
/// ``ServerProfile``. Because the account is the profile UUID, hosted and custom servers
/// occupy distinct keychain items and can never read one another's credentials.
///
/// Items are stored with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so tokens are available to the
/// running app after first unlock but never sync to iCloud Keychain or leave the device.
/// The data-protection keychain is used uniformly across platforms.
///
/// Security notes:
/// - Tokens are never written to `UserDefaults` and there is no plaintext fallback.
/// - The service identifier and account (a UUID) are the only non-secret labels; token
///   contents never appear in queries used for lookup, in errors, or in logs.
struct KeychainTokenStore: TokenStore {
    /// The default, stable service identifier for all Arkham Horror auth tokens.
    static let defaultService = "app.arkhamhorror.auth.token"

    private let service: String
    private let client: any KeychainClient

    /// Creates a store.
    ///
    /// - Parameters:
    ///   - service: The generic-password service label. Defaults to
    ///     ``defaultService``; overridable so tests can isolate their own namespace.
    ///   - client: The Security wrapper to use. Defaults to ``SecurityKeychainClient``;
    ///     tests inject an in-memory fake.
    init(
        service: String = KeychainTokenStore.defaultService,
        client: any KeychainClient = SecurityKeychainClient()
    ) {
        self.service = service
        self.client = client
    }

    func token(for profileID: UUID) async throws -> String? {
        var query = baseQuery(for: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, data) = client.copyData(matching: query)
        switch status {
        case errSecSuccess:
            guard let data, let token = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedData
            }
            return token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : token
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandledStatus(status)
        }
    }

    func save(_ token: String, for profileID: UUID) async throws {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KeychainError.emptyToken
        }
        guard let data = token.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }

        let query = baseQuery(for: profileID)
        let updated = client.update(query, with: [kSecValueData as String: data])
        switch updated {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            try add(data: data, query: query)
        default:
            throw KeychainError.unhandledStatus(updated)
        }
    }

    func deleteToken(for profileID: UUID) async throws {
        let status = client.delete(baseQuery(for: profileID))
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainError.unhandledStatus(status)
        }
    }

    func deleteAllTokens() async throws {
        // Deliberately omits `kSecAttrAccount`: a `SecItemDelete` query naming only the
        // item class and service (no account) matches and removes every token this
        // store's service holds, regardless of which profile UUID it belongs to. It
        // still cannot touch any other service/namespace, so this can never delete
        // credentials belonging to anything outside this store.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = client.delete(query)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainError.unhandledStatus(status)
        }
    }

    /// Adds a new item, resolving a duplicate-item race by falling back to an update.
    ///
    /// A concurrent writer may insert the item between our `update` (which returned
    /// `errSecItemNotFound`) and this `add`. In that case `SecItemAdd` reports
    /// `errSecDuplicateItem`; we retry the update so the final stored value is ours.
    private func add(data: Data, query: [String: Any]) throws {
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = client.add(attributes)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let retried = client.update(query, with: [kSecValueData as String: data])
            guard retried == errSecSuccess else {
                throw KeychainError.unhandledStatus(retried)
            }
        default:
            throw KeychainError.unhandledStatus(status)
        }
    }

    /// The identifying query shared by every operation for a given profile.
    ///
    /// Contains only non-secret attributes: the item class, the stable service label,
    /// the profile UUID as account, and the data-protection keychain flag.
    private func baseQuery(for profileID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
