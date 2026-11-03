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

    @Test("Every write-back string resolves in English and German with distinct copy")
    func writeBackStrings() throws {
        let reasons: [ArkhamDBWriteBackConflictReason] = [
            .remoteChanged, .campaignChanged, .pushUncertain, .targetAlreadyLinked,
            .boundaryUndone, .accountChanged, .unknown("future"),
        ]
        let resolutions = ArkhamDBWriteBackResolution.allCases
        let suffixes = reasons.map(\.messageKey)
            + resolutions.flatMap { [$0.titleKey, $0.explanationKey] }
            + resolutions.filter(\.requiresConfirmation).map(\.confirmationTitleKey)
            + [
                "toggle", "toggleAccessibility", "state.off", "state.idle", "state.pending",
                "state.running", "state.failed", "state.failedUncertain", "state.failedDisabled",
                "state.failedValidation",
                "state.succeeded", "state.cancelled", "state.unknown", "blocked", "spentXp",
                "retry", "retryAccessibility", "resolve", "details", "resolveAccessibility",
                "conflictTitle", "skipped", "skippedOne", "error.disabled", "error.conflict",
                "error.conflictRefreshFailed", "error.pushUncertain", "error.validationFailed",
                "error.confirmationRequired",
            ].map { "writeBack.\($0)" }
        #expect(suffixes.count == 44)
        let moduleURL = Bundle.module.bundleURL.deletingLastPathComponent()
            .appending(path: "ArkhamHorrorShared_ArkhamHorrorShared.bundle")
        let module = try #require(Bundle(url: moduleURL))
        var english: [String: String] = [:]
        for locale in ["en", "de"] {
            let url = try #require(module.url(forResource: locale, withExtension: "lproj"))
            let bundle = try #require(Bundle(url: url))
            for suffix in suffixes {
                let key = "arkhamdb.\(suffix)"
                let value = bundle.localizedString(forKey: key, value: "__missing__", table: nil)
                #expect(value != "__missing__" && value != key && !value.isEmpty, "\(key)")
                if locale == "en" {
                    english[key] = value
                } else if suffix != "writeBack.details" {
                    #expect(value != english[key], "\(key) is untranslated")
                }
            }
            let spent = bundle.localizedString(
                forKey: "arkhamdb.writeBack.spentXp", value: nil, table: nil
            )
            #expect(spent == (locale == "de"
                    ? "Ausgegebene EP werden nicht synchronisiert. "
                    + "Trage sie vor dem nächsten Upgrade manuell auf ArkhamDB ein."
                    : "Spent XP isn't synced. "
                    + "Set spent XP manually on ArkhamDB before the next upgrade."))
            let toggle = bundle.localizedString(
                forKey: "arkhamdb.writeBack.toggleAccessibility", value: nil, table: nil
            )
            #expect(String(format: toggle, "Roland") == (locale == "de"
                    ? "Roland an ArkhamDB zurückschreiben" : "Write Roland back to ArkhamDB"))
        }
    }

    @Test("Write-back confirmations name the deck they act on in en and de")
    func writeBackConfirmationsNameTheDeck() throws {
        let moduleURL = Bundle.module.bundleURL.deletingLastPathComponent()
            .appending(path: "ArkhamHorrorShared_ArkhamHorrorShared.bundle")
        let module = try #require(Bundle(url: moduleURL))
        for locale in ["en", "de"] {
            let url = try #require(module.url(forResource: locale, withExtension: "lproj"))
            let bundle = try #require(Bundle(url: url))
            let confirmed = ArkhamDBWriteBackResolution.allCases.filter(\.requiresConfirmation)
            for resolution in confirmed {
                let title = bundle.localizedString(
                    forKey: "arkhamdb.\(resolution.confirmationTitleKey)", value: nil, table: nil
                )
                #expect(String(format: title, "Roland").contains("Roland"), "\(locale) \(title)")
            }
        }
    }

    @Test("The four write-back error codes get specific messages, not the generic failure")
    func writeBackErrorMessages() {
        let cases: [(ArkhamDBErrorCode, String)] = [
            (.writeBackDisabled, "writeBack.error.disabled"),
            (.conflict, "writeBack.error.conflict"),
            (.pushUncertain, "writeBack.error.pushUncertain"),
            (.validationFailed, "writeBack.error.validationFailed"),
        ]
        for (code, suffix) in cases {
            let message = arkhamDBErrorMessage(ArkhamDBError(code: code, error: "server text"))
            #expect(message == arkhamDBLocalized(suffix))
            #expect(message != arkhamDBLocalized("failed"))
        }
        #expect(arkhamDBErrorMessage(nil) == arkhamDBLocalized("failed"))
        #expect(DeckServiceError.writeBackConflictStatusUnavailable.message
            == arkhamDBLocalized("writeBack.error.conflictRefreshFailed"))
        #expect(arkhamDBSkippedWriteBackText(1)
            == String(format: arkhamDBLocalized("writeBack.skippedOne"), 1))
        #expect(arkhamDBSkippedWriteBackText(2)
            == String(format: arkhamDBLocalized("writeBack.skipped"), 2))
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
