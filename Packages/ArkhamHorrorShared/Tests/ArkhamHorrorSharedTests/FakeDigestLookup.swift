@testable import ArkhamHorrorShared
import Foundation

/// A digest lookup fully controlled by tests: returns `true` only for the
/// exact `(identifier, locale)` pairs explicitly seeded.
struct FakeDigestLookup: LocalizedDigestLookup {
    let localized: Set<AssetIdentifier>

    init(localized: Set<AssetIdentifier> = []) {
        self.localized = localized
    }

    func hasLocalizedArt(_ identifier: AssetIdentifier, locale: AssetLocale) -> Bool {
        locale != .english && localized.contains(identifier)
    }
}
