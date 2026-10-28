@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("ArkhamDB localization")
struct ArkhamDBLocalizationTests {
    @Test("Account, browser and error strings resolve in English and German bundles")
    func bundledStrings() throws {
        let suffixes = [
            "account", "loading", "statusUnavailable", "unlinked", "linked", "linkedAs", "link",
            "relink",
            "unlink",
            "unlinkConfirmation", "unlinkExplanation", "anotherDevice", "refresh", "cancel",
            "decks",
            "skipped", "skippedOne", "empty", "updated", "imported", "import",
            "importAccessibility",
            "relinkRequired",
            "disabled", "remoteUnavailable", "failed", "denied", "presentationUnavailable",
        ]
        for locale in ["en", "de"] {
            let moduleURL = Bundle.module.bundleURL.deletingLastPathComponent()
                .appending(path: "ArkhamHorrorShared_ArkhamHorrorShared.bundle")
            let module = try #require(Bundle(url: moduleURL))
            let url = try #require(module.url(forResource: locale, withExtension: "lproj"))
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
            let singular = bundle.localizedString(
                forKey: "arkhamdb.skippedOne",
                value: nil,
                table: nil
            )
            #expect(String(format: singular, 1) == (locale == "de"
                    ? "1 ArkhamDB-Deckeintrag konnte nicht gelesen werden. "
                    + "Andere Decks werden unten angezeigt."
                    : "Could not read 1 ArkhamDB deck entry. Other decks are shown below."))
        }
    }

    @Test("Browser copy formats raw ArkhamDB date_update offsets and hides unreadable dates")
    func rawArkhamDBTimestamp() {
        let date = Date(timeIntervalSince1970: 1_714_564_800)
        let expected = String(
            format: arkhamDBLocalized("updated"),
            date.formatted(date: .abbreviated, time: .shortened)
        )
        #expect(arkhamDBUpdatedText("2024-05-01T12:00:00+00:00") == expected)
        #expect(arkhamDBUpdatedText("2024-05-01T12:00:00.123+00:00") == expected)
        #expect(arkhamDBUpdatedText("2024-05-01T14:00:00+02:00") == expected)
        #expect(arkhamDBUpdatedText("unreadable ArkhamDB date_update") == nil)
    }

    @Test("Browser copy formats timestamps and uses the singular skipped-entry message")
    func browserCopy() {
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        let expected = String(
            format: arkhamDBLocalized("updated"),
            date.formatted(date: .abbreviated, time: .shortened)
        )
        #expect(arkhamDBUpdatedText("2026-01-01T00:00:00Z") == expected)
        #expect(arkhamDBUpdatedText("2026-01-01T00:00:00.000Z") == expected)
        #expect(arkhamDBUpdatedText("not a timestamp") == nil)
        #expect(arkhamDBUpdatedText(nil) == nil)
        #expect(arkhamDBSkippedText(1) == String(format: arkhamDBLocalized("skippedOne"), 1))
        #expect(arkhamDBSkippedText(3) == String(format: arkhamDBLocalized("skipped"), 3))
    }
}
