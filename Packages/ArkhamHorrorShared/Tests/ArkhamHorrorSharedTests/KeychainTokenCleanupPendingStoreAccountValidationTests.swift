@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Coverage for ``KeychainTokenCleanupPendingStore/pendingProfileIDs()``'s exact
/// canonical-spelling requirement on each enumerated Keychain item's raw
/// `kSecAttrAccount` string — split out of `KeychainTokenCleanupPendingStoreTests.swift`
/// purely to stay within the type-body-length lint limit.
///
/// `UUID(uuidString:)` alone is case/format-tolerant and silently re-canonicalizes
/// whatever it is given, so accepting anything other than the *exact* canonical,
/// upper-case, unbraced spelling that every write path (`markPending`/`clearPending`)
/// always uses would let a non-canonical raw account string be reported as pending
/// while remaining permanently unclearable by `clearPending`, which always queries by
/// `profileID.uuidString` — a durable, unrecoverable tombstone.
extension KeychainTokenCleanupPendingStoreTests {
    @Test("A lower-case spelling of a valid UUID account is rejected as corrupt data")
    func lowercaseAccountSpellingRejected() {
        // `UUID(uuidString:)` alone would happily parse this and re-canonicalize it in
        // memory, but the actual Keychain item's account attribute is *not* the
        // canonical `profileWithLetters.uuidString` that `clearPending`'s own query
        // looks for, so accepting it here would report a tombstone that can never
        // actually be cleared.
        let store = makeStore(
            FixedAccountsKeychainClient(accounts: [profileWithLetters.uuidString.lowercased()])
        )
        #expect(throws: TokenCleanupPendingStoreError.corruptData) {
            _ = try store.pendingProfileIDs()
        }
    }

    @Test("A mixed-case spelling of a valid UUID account is rejected as corrupt data")
    func mixedCaseAccountSpellingRejected() {
        let canonical = profileWithLetters.uuidString
        let mixedCase = String(canonical.enumerated().map { index, character in
            index.isMultiple(of: 2) ? Character(character.lowercased()) : character
        })
        #expect(mixedCase != canonical)
        let store = makeStore(FixedAccountsKeychainClient(accounts: [mixedCase]))
        #expect(throws: TokenCleanupPendingStoreError.corruptData) {
            _ = try store.pendingProfileIDs()
        }
    }

    @Test("A braced or whitespace-decorated UUID account is rejected as corrupt data")
    func bracedOrWhitespaceAccountSpellingRejected() {
        let braced = makeStore(FixedAccountsKeychainClient(accounts: ["{\(profileA.uuidString)}"]))
        #expect(throws: TokenCleanupPendingStoreError.corruptData) {
            _ = try braced.pendingProfileIDs()
        }

        let padded = makeStore(FixedAccountsKeychainClient(accounts: [" \(profileA.uuidString)"]))
        #expect(throws: TokenCleanupPendingStoreError.corruptData) {
            _ = try padded.pendingProfileIDs()
        }
    }

    @Test("The exact canonical upper-case UUID spelling succeeds")
    func canonicalUppercaseAccountSpellingSucceeds() throws {
        let store = makeStore(FixedAccountsKeychainClient(accounts: [profileA.uuidString]))
        #expect(try store.pendingProfileIDs() == [profileA])
    }

    @Test(
        """
        A mixed array with one canonical and one non-canonical account fails closed \
        with no partial result
        """
    )
    func mixedArrayWithOneNonCanonicalAccountFailsClosed() {
        let store = makeStore(FixedAccountsKeychainClient(
            accounts: [profileA.uuidString, profileWithLetters.uuidString.lowercased()]
        ))
        // The whole query must fail closed rather than silently returning only the
        // canonical entries: a caller must never observe a normalized subset that
        // quietly drops an account the actual Keychain state cannot resolve.
        #expect(throws: TokenCleanupPendingStoreError.corruptData) {
            _ = try store.pendingProfileIDs()
        }
    }
}
