@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("AssetLocator")
struct AssetLocatorTests {
    private let source = AssetSourceNamespace.hosted

    private func key(_ category: AssetCategory, locale: AssetLocale = .english) -> AssetKey {
        AssetKey(source: source, category: category, locale: locale)
    }

    private func urls(_ candidates: [AssetCandidate]) -> [String] {
        candidates.map { $0.url(base: .hosted).absoluteString }
    }

    // MARK: - Card art fallback chain

    @Test(
        "A bare numeric card code always includes an alternate-front candidate, even with no locale"
    )
    func englishCardArtSingleCandidate() throws {
        let identifier = try AssetIdentifier.cardCode("01001")
        let candidates = AssetLocator.candidates(
            for: key(.card(.art, identifier)),
            digest: FakeDigestLookup()
        )
        #expect(urls(candidates) == [
            "https://assets.arkhamhorror.app:443/img/arkham/cards/01001.avif",
            "https://assets.arkhamhorror.app:443/img/arkham/cards/01001a.avif",
        ])
    }

    @Test("A localized locale with a digest hit produces [localized, english, alternateFront]")
    func localizedHitProducesThreeCandidatesInOrder() throws {
        let identifier = try AssetIdentifier.cardCode("13093")
        let candidates = AssetLocator.candidates(
            for: key(.card(.art, identifier), locale: .italian),
            digest: FakeDigestLookup(localized: [identifier])
        )
        #expect(urls(candidates) == [
            "https://assets.arkhamhorror.app:443/img/arkham/ita/cards/13093.avif",
            "https://assets.arkhamhorror.app:443/img/arkham/cards/13093.avif",
            "https://assets.arkhamhorror.app:443/img/arkham/cards/13093a.avif",
        ])
    }

    @Test("A localized locale with no digest entry skips the localized candidate entirely")
    func localizedMissDoesNotProduceLocalizedCandidate() throws {
        let identifier = try AssetIdentifier.cardCode("13093")
        let candidates = AssetLocator.candidates(
            for: key(.card(.art, identifier), locale: .italian),
            digest: FakeDigestLookup(localized: [])
        )
        #expect(urls(candidates) == [
            "https://assets.arkhamhorror.app:443/img/arkham/cards/13093.avif",
            "https://assets.arkhamhorror.app:443/img/arkham/cards/13093a.avif",
        ])
    }

    @Test("Korean's always-empty digest never produces a localized candidate")
    func koreanAlwaysFallsBackToEnglish() throws {
        let identifier = try AssetIdentifier.cardCode("13093")
        let candidates = AssetLocator.candidates(
            for: key(.card(.art, identifier), locale: .korean),
            digest: BundledLocalizedDigestProvider.shared
        )
        #expect(urls(candidates) == [
            "https://assets.arkhamhorror.app:443/img/arkham/cards/13093.avif",
            "https://assets.arkhamhorror.app:443/img/arkham/cards/13093a.avif",
        ])
    }

    @Test("A code with a side letter already present never gets an alternate-front candidate")
    func sideLetterCodeHasNoAlternateFront() throws {
        let identifier = try AssetIdentifier.cardCode("01001b")
        let candidates = AssetLocator.candidates(
            for: key(.card(.art, identifier)),
            digest: FakeDigestLookup()
        )
        #expect(urls(candidates) ==
            ["https://assets.arkhamhorror.app:443/img/arkham/cards/01001b.avif"])
    }

    @Test("A mutated code never gets an alternate-front candidate")
    func mutatedCodeHasNoAlternateFront() throws {
        let identifier = try AssetIdentifier.cardCode("04105_Mutated21")
        let candidates = AssetLocator.candidates(
            for: key(.card(.art, identifier)),
            digest: FakeDigestLookup()
        )
        #expect(urls(candidates) ==
            ["https://assets.arkhamhorror.app:443/img/arkham/cards/04105_Mutated21.avif"])
    }

    @Test("An x-prefixed special code never gets an alternate-front candidate")
    func xPrefixedCodeHasNoAlternateFront() throws {
        let identifier = try AssetIdentifier.cardCode("x05184")
        let candidates = AssetLocator.candidates(
            for: key(.card(.art, identifier)),
            digest: FakeDigestLookup()
        )
        #expect(urls(candidates) ==
            ["https://assets.arkhamhorror.app:443/img/arkham/cards/x05184.avif"])
    }

    @Test("Candidates never contain duplicates even when localized and english paths coincide")
    func candidatesContainNoDuplicates() throws {
        let identifier = try AssetIdentifier.cardCode("13093")
        let candidates = AssetLocator.candidates(
            for: key(.card(.art, identifier), locale: .italian),
            digest: FakeDigestLookup(localized: [identifier])
        )
        #expect(Set(candidates).count == candidates.count)
    }

    // MARK: - Homebrew card art is never localized

    @Test("Homebrew card art resolves under homebrew/<campaign>/cards/ and is never localized")
    func homebrewCardArtNeverLocalized() throws {
        let campaign = try AssetIdentifier.homebrewSlug("circus-ex-mortis")
        let art = try AssetIdentifier.cardCode("50001")
        let candidates = AssetLocator.candidates(
            for: key(.homebrewCard(campaign: campaign, art: art), locale: .italian),
            digest: FakeDigestLookup(localized: [art])
        )
        let base = "https://assets.arkhamhorror.app:443/img/arkham/homebrew/circus-ex-mortis"
        #expect(urls(candidates) == [
            "\(base)/cards/50001.avif",
            "\(base)/cards/50001a.avif",
        ])
    }

    // MARK: - Generic backs

    @Test("Encounter and player backs resolve to their fixed shared paths")
    func genericBacksResolveToFixedPaths() throws {
        let anyIdentifier = try AssetIdentifier.cardCode("01001")
        let encounter = AssetLocator.candidates(for: key(.card(
            .genericBack(.encounter),
            anyIdentifier
        )))
        let player = AssetLocator.candidates(for: key(.card(.genericBack(.player), anyIdentifier)))
        #expect(urls(encounter) ==
            ["https://assets.arkhamhorror.app:443/img/arkham/backs/back_encounter.jpg"])
        #expect(urls(player) ==
            ["https://assets.arkhamhorror.app:443/img/arkham/backs/back_player.jpg"])
    }

    @Test("A custom back carries its own identifier and format")
    func customBackUsesOwnIdentifierAndFormat() throws {
        let anyIdentifier = try AssetIdentifier.cardCode("01001")
        let backSlug = try AssetIdentifier.backSlug("children_of_blood")
        let candidates = AssetLocator.candidates(
            for: key(.card(.genericBack(.custom(backSlug, format: .avif)), anyIdentifier))
        )
        #expect(urls(candidates) ==
            ["https://assets.arkhamhorror.app:443/img/arkham/backs/children_of_blood.avif"])
    }

    // MARK: - Portraits, chaos tokens, set icons, boxes, slot icons

    @Test("Portraits resolve to portraits/<code>.jpg")
    func portraitsResolveCorrectly() throws {
        let identifier = try AssetIdentifier.cardCode("01001")
        let candidates = AssetLocator.candidates(for: key(.portrait(identifier)))
        #expect(urls(candidates) ==
            ["https://assets.arkhamhorror.app:443/img/arkham/portraits/01001.jpg"])
    }

    @Test("Chaos tokens resolve to chaos-tokens/ct-<face>.png")
    func chaosTokensResolveCorrectly() {
        let candidates = AssetLocator.candidates(for: key(.chaosToken(.elderSign)))
        #expect(urls(candidates) ==
            ["https://assets.arkhamhorror.app:443/img/arkham/chaos-tokens/ct-eldersign.png"])
    }

    @Test("Homebrew chaos tokens resolve under homebrew/<campaign>/chaos-tokens/")
    func homebrewChaosTokensResolveCorrectly() throws {
        let campaign = try AssetIdentifier.homebrewSlug("circus-ex-mortis")
        let tokenKey = try AssetIdentifier.homebrewTokenKey("moon")
        let candidates = AssetLocator.candidates(
            for: key(.homebrewChaosToken(campaign: campaign, key: tokenKey))
        )
        let base = "https://assets.arkhamhorror.app:443/img/arkham/homebrew/circus-ex-mortis"
        #expect(urls(candidates) == [
            "\(base)/chaos-tokens/moon.png",
        ])
    }

    @Test("A set icon with no variant resolves to sets/<id>.png")
    func setIconWithoutVariant() throws {
        let identifier = try AssetIdentifier.setOrBoxCode("01")
        let candidates = AssetLocator.candidates(for: key(.setIcon(identifier, variant: nil)))
        #expect(urls(candidates) == ["https://assets.arkhamhorror.app:443/img/arkham/sets/01.png"])
    }

    @Test("A set icon with a variant resolves to sets/<id>-<variant>.png")
    func setIconWithVariant() throws {
        let identifier = try AssetIdentifier.setOrBoxCode("01")
        let variant = try AssetIdentifier.setOrBoxCode("02")
        let candidates = AssetLocator.candidates(for: key(.setIcon(identifier, variant: variant)))
        #expect(urls(candidates) ==
            ["https://assets.arkhamhorror.app:443/img/arkham/sets/01-02.png"])
    }

    @Test("A homebrew set icon resolves under homebrew/<campaign>/sets/")
    func homebrewSetIconResolvesCorrectly() throws {
        let campaign = try AssetIdentifier.homebrewSlug("dark-matter")
        let identifier = try AssetIdentifier.setOrBoxCode("01")
        let candidates = AssetLocator.candidates(
            for: key(.homebrewSetIcon(campaign: campaign, identifier: identifier))
        )
        #expect(urls(candidates) == [
            "https://assets.arkhamhorror.app:443/img/arkham/homebrew/dark-matter/sets/01.png",
        ])
    }

    @Test("A campaign box resolves to boxes/<id>.jpg")
    func campaignBoxResolvesCorrectly() throws {
        let identifier = try AssetIdentifier.setOrBoxCode("60101")
        let candidates = AssetLocator.candidates(for: key(.campaignBox(identifier)))
        #expect(urls(candidates) ==
            ["https://assets.arkhamhorror.app:443/img/arkham/boxes/60101.jpg"])
    }

    @Test("A homebrew campaign box reuses the campaign slug as its own identifier")
    func homebrewCampaignBoxReusesSlug() throws {
        let campaign = try AssetIdentifier.homebrewSlug("dark-matter")
        let candidates = AssetLocator.candidates(for: key(.homebrewCampaignBox(campaign: campaign)))
        let base = "https://assets.arkhamhorror.app:443/img/arkham/homebrew/dark-matter"
        #expect(urls(candidates) == [
            "\(base)/boxes/dark-matter.jpg",
        ])
    }

    @Test(
        "Slot icons resolve to tokens/<slot>.png",
        arguments: [
            (SlotIcon.clue, "clue"), (SlotIcon.resource, "resource"), (
                SlotIcon.leadInvestigator,
                "lead-investigator"
            ),
        ]
    )
    func slotIconsResolveCorrectly(icon: SlotIcon, expectedName: String) {
        let candidates = AssetLocator.candidates(for: key(.slotIcon(icon)))
        #expect(urls(candidates) ==
            ["https://assets.arkhamhorror.app:443/img/arkham/tokens/\(expectedName).png"])
    }
}

extension AssetLocatorTests {
    // MARK: - resolvedBackIdentifier

    @Test(
        "resolvedBackIdentifier strips the front-side letter and appends 'b'",
        arguments: [
            ("01001a", "01001b"),
            ("01001c", "01001b"),
            ("01001e", "01001b"),
            ("01001g", "01001b"),
        ]
    )
    func resolvedBackIdentifierStripsAndAppendsB(front: String, expectedBack: String) throws {
        let identifier = try AssetIdentifier.cardCode(front)
        let resolved = AssetLocator.resolvedBackIdentifier(from: identifier)
        #expect(resolved.rawValue == expectedBack)
    }

    @Test(
        "resolvedBackIdentifier honors the pinned disambiguation overrides",
        arguments: [
            ("03276a", "03276ab"), ("03276b", "03276bb"), ("03279a", "03279ab"), (
                "03279b",
                "03279bb"
            ),
        ]
    )
    func resolvedBackIdentifierHonorsOverrides(front: String, expectedBack: String) throws {
        let identifier = try AssetIdentifier.cardCode(front)
        let resolved = AssetLocator.resolvedBackIdentifier(from: identifier)
        #expect(resolved.rawValue == expectedBack)
    }

    @Test(
        "resolvedBackIdentifier fails closed with no front-side letter or override",
        arguments: ["01001b", "01001d", "01001"]
    )
    func resolvedBackIdentifierFailsClosedForNonFrontSideInput(front: String) throws {
        let identifier = try AssetIdentifier.cardCode(front)
        let resolved = AssetLocator.resolvedBackIdentifier(from: identifier)
        #expect(resolved.rawValue == front)
    }

    // MARK: - Determinism

    @Test("Resolving the same key twice against the same digest produces identical candidate lists")
    func resolutionIsDeterministic() throws {
        let identifier = try AssetIdentifier.cardCode("13093")
        let digest = FakeDigestLookup(localized: [identifier])
        let first = AssetLocator.candidates(
            for: key(.card(.art, identifier), locale: .italian),
            digest: digest
        )
        let second = AssetLocator.candidates(
            for: key(.card(.art, identifier), locale: .italian),
            digest: digest
        )
        #expect(first == second)
    }
}
