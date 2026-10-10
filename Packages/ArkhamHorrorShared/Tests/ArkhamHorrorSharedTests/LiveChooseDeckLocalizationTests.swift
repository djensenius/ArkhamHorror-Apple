import Foundation
import Testing

@Suite("Live ChooseDeck localization")
struct LiveChooseDeckLocalizationTests {
    private static let englishRestrictionUnavailable =
        "Side-story investigator requirements could not be verified. "
            + "The server will check this deck when you submit it."
    private static let germanRestrictionChecking =
        "Anforderungen an Ermittlerdecks für Nebengeschichten werden geprüft …"
    private static let germanRestrictionUnavailable =
        "Anforderungen an Ermittlerdecks für Nebengeschichten konnten nicht geprüft werden. "
            + "Der Server prüft dieses Deck beim Absenden."

    private let expectedValues: [String: [String: String]] = [
        "en": [
            "liveChooseDeck.heading.generic": "Choose a Deck",
            "liveChooseDeck.error.requiresInvestigator": "This scenario requires %@",
            "liveChooseDeck.restriction.checking": "Checking side-story deck requirements…",
            "liveChooseDeck.restriction.unavailable": Self.englishRestrictionUnavailable,
        ],
        "de": [
            "liveChooseDeck.heading.generic": "Deck wählen",
            "liveChooseDeck.error.requiresInvestigator": "Dieses Szenario erfordert %@",
            "liveChooseDeck.restriction.checking": Self.germanRestrictionChecking,
            "liveChooseDeck.restriction.unavailable": Self.germanRestrictionUnavailable,
        ],
    ]

    @Test("Live ChooseDeck copy is localized in English and German bundles")
    func liveChooseDeckCopyIsLocalized() throws {
        for (language, values) in expectedValues {
            let strings = try localizableStringsText(for: language)
            for (key, value) in values {
                #expect(strings.contains("\"\(key)\" = \"\(value)\";"))
            }
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
