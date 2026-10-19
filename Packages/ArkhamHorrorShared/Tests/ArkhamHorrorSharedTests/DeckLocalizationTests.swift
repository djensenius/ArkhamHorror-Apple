@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Deck localization")
struct DeckLocalizationTests {
    @Test("Deck sync strings resolve in English and German bundles")
    func syncStringsResolveFromModuleBundle() throws {
        let keys = [
            "deck.refreshAndSync",
            "deck.sync.action",
            "deck.sync.accessibility",
            "deck.sync.status.syncing",
            "deck.sync.success",
            "deck.sync.staleFallback",
            "deck.sync.staleFallback.unknownDate",
            "deck.syncAll.none",
            "deck.syncAll.summary",
        ]
        for locale in ["en", "de"] {
            let bundle = try moduleBundle(locale: locale)
            for key in keys {
                let value = NSLocalizedString(
                    key,
                    bundle: bundle,
                    value: "__missing__",
                    comment: ""
                )
                #expect(value != "__missing__", "Missing localized value for \(key) in \(locale)")
                #expect(!value.isEmpty, "Empty localized value for \(key) in \(locale)")
            }
        }
    }

    private func moduleBundle(locale: String) throws -> Bundle {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/ArkhamHorrorShared/Localization")
            .appending(path: "\(locale).lproj")
        return try #require(Bundle(url: url))
    }
}
