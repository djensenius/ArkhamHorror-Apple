@testable import ArkhamHorrorShared
import Foundation

/// A digest lookup fully controlled by tests: returns `true` for any
/// non-English locale when the identifier is in the seeded set, and `false`
/// otherwise. Every current call site only varies the identifier set (never
/// distinguishes between two non-English locales for the same identifier),
/// so this coarser-than-`(identifier, locale)` granularity is sufficient;
/// if a future test needs true per-locale seeding, extend `localized` to a
/// `Set<AssetIdentifier, AssetLocale>`-keyed structure rather than
/// reinterpreting this comment.
struct FakeDigestLookup: LocalizedDigestLookup {
    let localized: Set<AssetIdentifier>

    init(localized: Set<AssetIdentifier> = []) {
        self.localized = localized
    }

    func hasLocalizedArt(_ identifier: AssetIdentifier, locale: AssetLocale) -> Bool {
        locale != .english && localized.contains(identifier)
    }
}
