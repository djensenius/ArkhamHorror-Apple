@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Game lifecycle localization")
struct GameLifecycleLocalizationTests {
    private let expectedValues: [String: [String: String]] = [
        "en": [
            "common.dismiss": "Dismiss",
            "games.broken.title": "Broken game",
            "games.live.roomClosed.message": "This game was closed on the server.",
            "games.live.roomClosed.message.abandoned":
                "Every player left this game, so the server closed its room.",
            "games.live.roomClosed.message.maintenance":
                "The server is down for maintenance. Open the game again once it is back.",
            "games.live.roomClosed.title": "Game closed",
        ],
        "de": [
            "common.dismiss": "Schließen",
            "games.broken.title": "Beschädigtes Spiel",
            "games.live.roomClosed.message": "Dieses Spiel wurde auf dem Server geschlossen.",
            "games.live.roomClosed.message.abandoned":
                "Alle Spieler haben dieses Spiel verlassen, "
                + "daher hat der Server den Raum geschlossen.",
            "games.live.roomClosed.message.maintenance":
                "Der Server wird gerade gewartet. "
                + "Öffne das Spiel erneut, sobald er wieder erreichbar ist.",
            "games.live.roomClosed.title": "Spiel geschlossen",
        ],
    ]

    @Test("Broken-game and room-closed strings resolve in English and German bundles")
    func gameLifecycleStringsResolveFromBundles() throws {
        for (language, values) in expectedValues {
            let bundle = try moduleBundle(locale: language)
            for (key, value) in values {
                #expect(NSLocalizedString(
                    key,
                    bundle: bundle,
                    value: "__missing__",
                    comment: ""
                ) == value)
            }
        }
    }

    private func moduleBundle(locale: String) throws -> Bundle {
        let packageURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bundleURL = packageURL
            .appending(path: "Sources/ArkhamHorrorShared/Localization")
            .appending(path: "\(locale).lproj")
        return try #require(Bundle(url: bundleURL))
    }
}
