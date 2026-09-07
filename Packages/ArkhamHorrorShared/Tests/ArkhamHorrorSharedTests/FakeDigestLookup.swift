@testable import ArkhamHorrorShared
import Foundation

/// A digest lookup fully controlled by tests: returns `true` for any
/// non-English locale when the identifier is in the seeded set, and `false`
/// otherwise. Every current call site only varies the identifier set (never
/// distinguishes between two non-English locales for the same identifier),
/// so this coarser-than-`(identifier, locale)` granularity is sufficient;
/// if a future test needs true per-locale seeding, extend `localized` to a
/// `Set<AssetLocalizedKey>` of a small `Hashable` struct pairing
/// `AssetIdentifier` and `AssetLocale`, rather than reinterpreting this
/// comment.
struct FakeDigestLookup: LocalizedDigestLookup {
    let localized: Set<AssetIdentifier>

    init(localized: Set<AssetIdentifier> = []) {
        self.localized = localized
    }

    func hasLocalizedArt(_ identifier: AssetIdentifier, locale: AssetLocale) -> Bool {
        locale != .english && localized.contains(identifier)
    }
}

/// A digest lookup standing in for a genuinely broken production
/// ``BundledLocalizedDigestProvider.shared`` (its backing resource
/// missing, unreadable, or malformed): every non-English identifier would
/// otherwise resolve `hasLocalizedArt` to `false`, indistinguishable from
/// a legitimately non-localized identifier, and silently fall back to the
/// English candidate as if nothing were wrong. Setting
/// ``configurationError`` here reproduces exactly that broken shape so
/// tests can prove ``AssetCacheService/resolvedCandidates(for:)`` throws
/// the typed error immediately instead of ever reaching that silent
/// substitution.
struct FailingDigestLookup: LocalizedDigestLookup {
    let configurationError: AssetError?

    init(configurationError: AssetError = .configurationFailure("test-injected failure")) {
        self.configurationError = configurationError
    }

    func hasLocalizedArt(_: AssetIdentifier, locale _: AssetLocale) -> Bool {
        false
    }
}
