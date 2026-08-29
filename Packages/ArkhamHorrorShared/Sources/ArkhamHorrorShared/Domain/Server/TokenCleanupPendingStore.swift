import Foundation
import Security

/// Errors produced when reading from or writing to a ``TokenCleanupPendingStore``.
///
/// No case carries a marker's raw bytes, a profile's server URL, or any token
/// material — only an opaque, non-secret `OSStatus` (already treated as safe to
/// surface/log elsewhere in this codebase; see ``KeychainError``) or a decoding-shape
/// mismatch.
enum TokenCleanupPendingStoreError: Error, Equatable, Sendable {
    /// Persisted data for the pending-cleanup record exists but could not be decoded.
    case corruptData
    /// The Security framework returned a status this store does not handle.
    /// `errSecItemNotFound` is handled distinctly (absent marker / no-op clear) and is
    /// never reported through this case.
    case unhandledStatus(OSStatus)
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

/// A ``TokenCleanupPendingStore`` backed by Security framework generic-password
/// Keychain items, under a service **distinct** from ``KeychainTokenStore``'s.
///
/// `UserDefaults` cannot back this store: a `UserDefaults` mutation does not
/// synchronously acknowledge durable storage or failure the way a Keychain
/// `SecItemAdd`/`SecItemUpdate`/`SecItemDelete` call's returned `OSStatus` does, so it
/// cannot make crash-durability claims a tombstone protecting Keychain credentials
/// actually needs.
///
/// Each pending-cleanup marker is a generic-password item whose account is the
/// canonical profile `UUID` string (exactly like ``KeychainTokenStore``) but whose
/// *service* is ``defaultService`` — a namespace the token store itself never reads,
/// writes, or enumerates, and vice versa. This separation is deliberate and
/// security-critical: a full-service `deleteAll` on the *token* service (see
/// ``TokenStore/deleteAllTokens()``) must never incidentally erase the durable
/// crash-recovery record before this store's own ``clearAll()`` has had a chance to
/// acknowledge it, and enumerating this store's markers (``pendingProfileIDs()``)
/// must never enumerate or expose a single byte of actual token data.
///
/// Marker values are a single fixed, non-secret byte — never a token, a token
/// fingerprint, or any other secret material — stored with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, matching ``KeychainTokenStore``'s
/// data-protection policy exactly (available after first unlock, never synced to
/// iCloud Keychain, never leaves the device).
struct KeychainTokenCleanupPendingStore: TokenCleanupPendingStore {
    /// The default, stable service identifier for pending-cleanup tombstones —
    /// distinct from ``KeychainTokenStore/defaultService``.
    static let defaultService = "app.arkhamhorror.auth.cleanup-pending"

    /// A single, fixed, non-secret marker byte. Every pending-cleanup item shares this
    /// exact value; only the item's existence (keyed by account = profile UUID)
    /// carries meaning.
    private static let markerValue = Data([0x01])

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
        service: String = KeychainTokenCleanupPendingStore.defaultService,
        client: any KeychainClient = SecurityKeychainClient()
    ) {
        self.service = service
        self.client = client
    }

    func pendingProfileIDs() throws -> Set<UUID> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let (status, accounts) = client.copyMatchingAccounts(matching: query)
        switch status {
        case errSecSuccess:
            guard let accounts else { throw TokenCleanupPendingStoreError.corruptData }
            var ids = Set<UUID>()
            for account in accounts {
                // Every marker this store itself ever writes uses exactly
                // `profileID.uuidString` (always canonical, upper-case, unbraced) as
                // its account — see `markPending`/`baseQuery(for:)` — and `clearPending`
                // and `resolvePendingCleanup` likewise only ever query/delete by that
                // same canonical form. `UUID(uuidString:)` alone is not enough to
                // guard that invariant: it happily accepts lower-case, mixed-case, or
                // whitespace/brace-decorated spellings and silently re-canonicalizes
                // them, which would let a raw account string that does *not* actually
                // match what `clearPending`'s query looks for be reported as pending
                // here, yet never actually be clearable — an un-clearable tombstone
                // that permanently (and silently) blocks that profile's credential
                // use. Requiring an exact round-trip match against the same
                // `uuidString` representation fails closed on any such alternate
                // spelling instead, exactly like an unparseable string.
                guard let uuid = UUID(uuidString: account), uuid.uuidString == account else {
                    throw TokenCleanupPendingStoreError.corruptData
                }
                ids.insert(uuid)
            }
            return ids
        case errSecItemNotFound:
            return []
        default:
            throw TokenCleanupPendingStoreError.unhandledStatus(status)
        }
    }

    func markPending(_ profileID: UUID) throws {
        let query = baseQuery(for: profileID)
        let updated = client.update(query, with: [kSecValueData as String: Self.markerValue])
        switch updated {
        case errSecSuccess:
            // Already pending: idempotent success, matching the value in place.
            return
        case errSecItemNotFound:
            try add(query: query)
        default:
            throw TokenCleanupPendingStoreError.unhandledStatus(updated)
        }
    }

    func clearPending(_ profileID: UUID) throws {
        let status = client.delete(baseQuery(for: profileID))
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw TokenCleanupPendingStoreError.unhandledStatus(status)
        }
    }

    func clearAll() throws {
        // Deliberately omits `kSecAttrAccount`, exactly like
        // ``TokenStore/deleteAllTokens()``: matches and removes every marker under
        // this store's *own* service, regardless of which profile it names, and can
        // never touch any other service/namespace.
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
            throw TokenCleanupPendingStoreError.unhandledStatus(status)
        }
    }

    /// Adds a new marker item, resolving a duplicate-item race by falling back to an
    /// update — mirrors ``KeychainTokenStore``'s identical add/update race handling.
    private func add(query: [String: Any]) throws {
        var attributes = query
        attributes[kSecValueData as String] = Self.markerValue
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = client.add(attributes)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let retried = client.update(query, with: [kSecValueData as String: Self.markerValue])
            guard retried == errSecSuccess else {
                throw TokenCleanupPendingStoreError.unhandledStatus(retried)
            }
        default:
            throw TokenCleanupPendingStoreError.unhandledStatus(status)
        }
    }

    /// The identifying query shared by every operation for a given profile. Contains
    /// only non-secret attributes: the item class, this store's own service label
    /// (distinct from the token store's), the profile UUID as account, and the
    /// data-protection keychain flag.
    private func baseQuery(for profileID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
