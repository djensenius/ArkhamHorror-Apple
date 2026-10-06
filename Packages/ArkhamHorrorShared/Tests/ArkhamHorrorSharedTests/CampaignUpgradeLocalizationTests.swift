@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Campaign upgrade localization")
struct CampaignUpgradeLocalizationTests {
    private let expectedValues: [String: [String: String]] = [
        "en": [
            "campaign.upgrade.replacementRequired":
                "This investigator was killed or driven insane. Choose a replacement "
                + "investigator deck to continue.",
            "campaign.upgrade.submitReplacement": "Submit replacement",
            "campaign.upgrade.savedDecks": "Saved decks",
            "campaign.upgrade.loadingDecks": "Loading saved decks…",
            "campaign.upgrade.retryDecks": "Retry saved decks",
            "campaign.upgrade.noSavedDecks": "No saved decks are available.",
            "campaign.upgrade.checkingDeck": "Checking server support…",
            "campaign.upgrade.validDeck": "Server can play this deck's main cards.",
        ],
        "de": [
            "campaign.upgrade.replacementRequired":
                "Dieser Ermittler wurde getötet oder in den Wahnsinn getrieben. "
                + "Wähle ein Ersatzermittler-Deck, um fortzufahren.",
            "campaign.upgrade.submitReplacement": "Ersatz senden",
            "campaign.upgrade.savedDecks": "Gespeicherte Decks",
            "campaign.upgrade.loadingDecks": "Gespeicherte Decks werden geladen …",
            "campaign.upgrade.retryDecks": "Gespeicherte Decks erneut laden",
            "campaign.upgrade.noSavedDecks": "Es sind keine gespeicherten Decks verfügbar.",
            "campaign.upgrade.checkingDeck": "Server-Unterstützung wird geprüft …",
            "campaign.upgrade.validDeck": "Der Server kann die Hauptkarten dieses Decks spielen.",
        ],
    ]

    @Test("Campaign upgrade strings exist in English and German bundles")
    func campaignUpgradeStringsExist() throws {
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
