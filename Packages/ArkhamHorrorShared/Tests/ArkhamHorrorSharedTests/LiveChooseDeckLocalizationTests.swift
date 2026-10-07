import Foundation
import Testing

@Suite("Live ChooseDeck localization")
struct LiveChooseDeckLocalizationTests {
    private let expectedValues: [String: String] = [
        "en": "Choose a Deck",
        "de": "Deck wählen",
    ]

    @Test("Live ChooseDeck generic heading is localized in English and German bundles")
    func liveChooseDeckGenericHeadingIsLocalized() throws {
        for (language, value) in expectedValues {
            let strings = try localizableStringsText(for: language)
            #expect(strings.contains("\"liveChooseDeck.heading.generic\" = \"\(value)\";"))
        }
    }

    private func localizableStringsText(for language: String) throws -> String {
        let packageURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let stringsURL = packageURL
            .appending(path: "Sources/ArkhamHorrorShared/Localization")
            .appending(path: "\(language).lproj/Localizable.strings")
        return try String(contentsOf: stringsURL, encoding: .utf8)
    }
}
