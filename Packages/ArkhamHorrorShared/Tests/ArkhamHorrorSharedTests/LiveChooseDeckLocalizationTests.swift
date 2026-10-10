import Foundation
import Testing

@Suite("Live ChooseDeck localization")
struct LiveChooseDeckLocalizationTests {
    private static let englishRestrictionUnavailable =
        "Side-story investigator requirements cannot be checked right now. "
            + "Make sure this deck uses the scenario's required investigator."
    private static let englishMultiplayerUnavailable =
        "Side-story investigator requirements cannot be fully checked from the current table "
            + "state. Make sure one player uses the scenario's required investigator."
    private static let germanRestrictionChecking =
        "Anforderungen an Ermittlerdecks für Nebengeschichten werden geprüft …"
    private static let germanRestrictionUnavailable =
        "Anforderungen an Ermittlerdecks für Nebengeschichten können derzeit nicht geprüft "
            + "werden. Stelle sicher, dass dieses Deck den für das Szenario erforderlichen "
            + "Ermittler verwendet."
    private static let germanMultiplayerUnavailable =
        "Anforderungen an Ermittlerdecks für Nebengeschichten können anhand des aktuellen "
            + "Tischzustands nicht vollständig geprüft werden. Stelle sicher, dass ein Spieler "
            + "den für das Szenario erforderlichen Ermittler verwendet."

    private let expectedValues: [String: [String: String]] = [
        "en": [
            "liveChooseDeck.heading.generic": "Choose a Deck",
            "liveChooseDeck.error.requiresInvestigator": "This scenario requires %@",
            "liveChooseDeck.error.requiresSpecificInvestigator":
                "This scenario requires a specific investigator",
            "liveChooseDeck.restriction.checking": "Checking side-story deck requirements…",
            "liveChooseDeck.restriction.multiplayerUnavailable":
                Self.englishMultiplayerUnavailable,
            "liveChooseDeck.restriction.unavailable": Self.englishRestrictionUnavailable,
            "liveChooseDeck.readOnly.notChoosingDeck":
                "This game is not currently asking you to choose a deck.",
            "liveChooseDeck.readOnly.spectator":
                "Spectators cannot choose decks for this game.",
            "liveChooseDeck.readOnly.otherPlayer":
                "This deck choice belongs to another player.",
            "liveChooseDeck.readOnly.incompatibleServer":
                "Update or reconnect to a contract-compatible server to choose a deck.",
            "liveChooseDeck.readOnly.reconnect": "Reconnect to choose a deck.",
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
            "liveChooseDeck.restriction.multiplayerUnavailable":
                Self.germanMultiplayerUnavailable,
            "liveChooseDeck.restriction.unavailable": Self.germanRestrictionUnavailable,
            "liveChooseDeck.readOnly.notChoosingDeck":
                "Dieses Spiel fordert dich derzeit nicht auf, ein Deck zu wählen.",
            "liveChooseDeck.readOnly.spectator":
                "Zuschauer können für dieses Spiel keine Decks wählen.",
            "liveChooseDeck.readOnly.otherPlayer":
                "Diese Deckwahl gehört einem anderen Spieler.",
            "liveChooseDeck.readOnly.incompatibleServer":
                "Aktualisiere die Verbindung oder verbinde dich erneut mit einem "
                + "vertragskompatiblen Server, um ein Deck zu wählen.",
            "liveChooseDeck.readOnly.reconnect":
                "Verbinde dich erneut, um ein Deck zu wählen.",
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
