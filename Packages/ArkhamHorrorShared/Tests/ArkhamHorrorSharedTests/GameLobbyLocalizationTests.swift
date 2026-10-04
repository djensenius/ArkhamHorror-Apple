@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Game lobby localization")
struct GameLobbyLocalizationTests {
    private let expectedValues: [String: [String: String]] = [
        "en": [
            "games.lobby.openSeats.checkingSeat":
                "Checking whether you already have a seat in this game.",
            "games.lobby.openSeats.checkingSeat.loading": "Checking seat status…",
            "games.lobby.openSeats.checkingSeat.failed":
                "Could not check whether you already have a seat: %@",
            "games.lobby.openSeats.checkingSeat.retry": "Retry Seat Check",
        ],
        "de": [
            "games.lobby.openSeats.checkingSeat":
                "Es wird geprüft, ob du bereits einen Platz in diesem Spiel hast.",
            "games.lobby.openSeats.checkingSeat.loading": "Platzstatus wird geprüft …",
            "games.lobby.openSeats.checkingSeat.failed":
                "Es konnte nicht geprüft werden, ob du bereits einen Platz hast: %@",
            "games.lobby.openSeats.checkingSeat.retry": "Platzprüfung wiederholen",
        ],
    ]

    @Test("Viewer membership status strings exist in English and German bundles")
    func viewerMembershipStatusStringsExist() throws {
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
