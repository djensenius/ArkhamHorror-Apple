import Foundation
import Testing

@Suite("Live ChooseDeck localization")
struct LiveChooseDeckLocalizationTests {
    private static let englishRestrictionUnavailable =
        "Side-story investigator requirements cannot be checked right now. "
            + "Make sure this deck uses the scenario's required investigator."
    private static let germanRestrictionChecking =
        "Anforderungen an Ermittlerdecks für Nebengeschichten werden geprüft …"
    private static let germanRestrictionUnavailable =
        "Anforderungen an Ermittlerdecks für Nebengeschichten können derzeit nicht geprüft "
            + "werden. Stelle sicher, dass dieses Deck den für das Szenario erforderlichen "
            + "Ermittler verwendet."

    private let expectedValues: [String: [String: String]] = [
        "en": [
            "liveChooseDeck.heading.generic": "Choose a Deck",
            "liveChooseDeck.error.requiresInvestigator": "This scenario requires %@",
            "liveChooseDeck.error.requiresSpecificInvestigator":
                "This scenario requires a specific investigator",
            "liveChooseDeck.restriction.checking": "Checking side-story deck requirements…",
            "liveChooseDeck.restriction.unavailable": Self.englishRestrictionUnavailable,
            "liveChooseDeck.sendFailure":
                "This deck could not be sent. Reconnect and try again.",
            "liveChooseDeck.loadingSavedDecks": "Loading saved decks…",
            "liveChooseDeck.retrySavedDecks": "Retry Saved Decks",
            "liveChooseDeck.noSavedDecks":
                "Import a deck from the Decks screen before choosing a deck.",
            "liveChooseDeck.checkingDeck": "Checking server support…",
            "liveChooseDeck.validDeck": "Server can play this deck's main cards.",
        ],
        "de": [
            "liveChooseDeck.heading.generic": "Deck wählen",
            "liveChooseDeck.error.requiresInvestigator": "Dieses Szenario erfordert %@",
            "liveChooseDeck.error.requiresSpecificInvestigator":
                "Dieses Szenario erfordert einen bestimmten Ermittler",
            "liveChooseDeck.restriction.checking": Self.germanRestrictionChecking,
            "liveChooseDeck.restriction.unavailable": Self.germanRestrictionUnavailable,
            "liveChooseDeck.sendFailure":
                "Dieses Deck konnte nicht gesendet werden. Stelle die Verbindung wieder her und "
                + "versuche es erneut.",
            "liveChooseDeck.loadingSavedDecks": "Gespeicherte Decks werden geladen …",
            "liveChooseDeck.retrySavedDecks": "Gespeicherte Decks erneut laden",
            "liveChooseDeck.noSavedDecks":
                "Importiere ein Deck über den Decks-Bildschirm, bevor du ein Deck wählst.",
            "liveChooseDeck.checkingDeck": "Server-Unterstützung wird geprüft …",
            "liveChooseDeck.validDeck":
                "Der Server kann die Hauptkarten dieses Decks spielen.",
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
