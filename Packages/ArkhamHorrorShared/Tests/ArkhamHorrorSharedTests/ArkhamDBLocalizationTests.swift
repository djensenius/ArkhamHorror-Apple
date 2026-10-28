@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("ArkhamDB localization")
struct ArkhamDBLocalizationTests {
    @Test("Account, browser and error strings resolve in English and German bundles")
    func bundledStrings() throws {
        let suffixes = [
            "account", "loading", "unlinked", "linked", "linkedAs", "link", "relink", "unlink",
            "unlinkConfirmation", "unlinkExplanation", "anotherDevice", "refresh", "cancel",
            "decks",
            "skipped", "empty", "updated", "imported", "import", "importAccessibility",
            "relinkRequired",
            "disabled", "remoteUnavailable", "failed", "denied",
        ]
        #expect(arkhamDBLocalized("linked") == "Linked")
        for locale in ["en", "de"] {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Sources/ArkhamHorrorShared/Localization/\(locale).lproj")
            let bundle = try #require(Bundle(url: url))
            for suffix in suffixes {
                let key = "arkhamdb.\(suffix)"
                let value = bundle.localizedString(forKey: key, value: "__missing__", table: nil)
                #expect(value != "__missing__" && value != key && !value.isEmpty)
            }
            let linked = bundle.localizedString(forKey: "arkhamdb.linkedAs", value: nil, table: nil)
            #expect(String(format: linked, "Investigator") ==
                (locale == "de" ? "Verknüpft als Investigator" : "Linked as Investigator"))
            let skipped = bundle.localizedString(forKey: "arkhamdb.skipped", value: nil, table: nil)
            #expect(String(format: skipped, 3).contains("3"))
            #expect(!String(format: skipped, 3).contains("%"))
        }
    }
}
