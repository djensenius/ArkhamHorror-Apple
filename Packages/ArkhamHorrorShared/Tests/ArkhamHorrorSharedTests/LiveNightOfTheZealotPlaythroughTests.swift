// swiftlint:disable file_length
@testable import ArkhamHorrorShared
import Foundation
import Testing

// Env-gated live-server smoke coverage. It is intentionally absent from normal CI
// unless `ARKHAM_LIVE_SERVER_URL` is set; when enabled it drives the production
// `AppModel` authentication, lifecycle, REST snapshot and WebSocket answer paths
// against a real fork server.

private func liveServerURLForPlaythrough() -> String? {
    guard let rawURL = ProcessInfo.processInfo.environment["ARKHAM_LIVE_SERVER_URL"],
          !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return rawURL
}

private enum PlaythroughTarget: Sendable, Equatable {
    case campaign(id: String)
    case standaloneScenario(id: String)

    var displayName: String {
        switch self {
        case let .campaign(id): "Campaign \(id)"
        case let .standaloneScenario(id): "Standalone scenario \(id)"
        }
    }

    var summary: String {
        switch self {
        case let .campaign(id): "campaignId=\(id), scenarioId=null"
        case let .standaloneScenario(id): "campaignId=null, scenarioId=\(id)"
        }
    }

    var slug: String {
        switch self {
        case let .campaign(id): "campaign-\(slugComponent(id))"
        case let .standaloneScenario(id): "scenario-\(slugComponent(id))"
        }
    }

    var isNightOfTheZealotCampaign: Bool {
        self == .campaign(id: "01")
    }

    var defaultAchievementsEnabled: Bool {
        switch self {
        case .campaign: true
        case .standaloneScenario: false
        }
    }
}

private let returnToCampaignBaseIDs = [
    "50": "01",
    "51": "02",
    "52": "03",
    "53": "04",
    "54": "05",
]

private let officialCampaignIDs = Set([
    "01", "02", "03", "04", "05", "06", "07", "08", "09", "10", "11", "12", "13",
])

private func defaultStrictAsIfAt(for target: PlaythroughTarget) -> Bool {
    switch target {
    case let .campaign(id):
        return webCampaignChapter(forCampaignID: id) == 2
    case let .standaloneScenario(id):
        guard let campaignID = campaignIDForStandaloneScenario(id) else { return false }
        return webCampaignChapter(forCampaignID: campaignID) == 2
    }
}

private func webCampaignChapter(forCampaignID campaignID: String) -> Int {
    let baseCampaignID = returnToCampaignBaseIDs[campaignID] ?? campaignID
    guard !baseCampaignID.hasPrefix(":"), officialCampaignIDs.contains(baseCampaignID) else {
        return 1
    }
    // Matches the fork frontend's NewCampaign.vue watcher and data.ts campaignChapter:
    // explicit campaign catalog chapters would win there; official campaign ids >= 11
    // default to Chapter 2, and earlier/unknown/homebrew ids default to Chapter 1.
    return baseCampaignID >= "11" ? 2 : 1
}

private func campaignIDForStandaloneScenario(_ scenarioID: String) -> String? {
    let normalizedID = scenarioID.hasPrefix("c") ? String(scenarioID.dropFirst()) : scenarioID
    guard normalizedID.count >= 2 else { return nil }
    let prefix = String(normalizedID.prefix(2))
    if let returnToBaseCampaignID = returnToCampaignBaseIDs[prefix] {
        return returnToBaseCampaignID
    }
    return officialCampaignIDs.contains(prefix) ? prefix : nil
}

private struct LivePlaythroughConfiguration: Sendable, Equatable {
    let target: PlaythroughTarget
    let difficulty: RequestDifficulty
    let campaignVariants: [String]
    let includeTarotReadings: Bool
    let strictAsIfAt: Bool
    let ultimatumsAndBoons: [UltimatumOrBoon]
    let achievementsEnabled: Bool
    let investigators: [InvestigatorFixture]
    let resultPath: String
    let shouldWriteLegacyNightOfTheZealotSummary: Bool

    var options: [CampaignOption] {
        campaignVariants.map(CampaignOption.campaignVariant)
    }

    var strictAsIfAtField: OptionalField<Bool> {
        .value(strictAsIfAt)
    }

    var asIfRulingField: OptionalField<AsIfRuling> {
        .value(strictAsIfAt ? .chapter2 : .chapter1)
    }

    var ultimatumsAndBoonsField: OptionalField<[UltimatumOrBoon]> {
        ultimatumsAndBoons.isEmpty ? .absent : .value(ultimatumsAndBoons)
    }

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> LivePlaythroughConfiguration {
        let explicitCampaignID = trimmedValue("ARKHAM_LIVE_CAMPAIGN_ID", in: environment)
        let standaloneScenarioID = trimmedValue("ARKHAM_LIVE_SCENARIO_ID", in: environment)
        if explicitCampaignID != nil, standaloneScenarioID != nil {
            throw LiveHarnessConfigurationError.bothCampaignAndScenario
        }
        let target: PlaythroughTarget = if let standaloneScenarioID {
            .standaloneScenario(id: standaloneScenarioID)
        } else {
            .campaign(id: explicitCampaignID ?? "01")
        }
        let difficulty = try parseDifficulty(
            trimmedValue("ARKHAM_LIVE_DIFFICULTY", in: environment) ?? "Easy"
        )
        let investigators = try parseInvestigators(
            trimmedValue("ARKHAM_LIVE_INVESTIGATOR_CODES", in: environment),
            target: target
        )
        let resultPath = trimmedValue("ARKHAM_LIVE_RESULT_PATH", in: environment)
            ?? "/tmp/arkham-logs/playthrough-results-\(target.slug).md"
        let shouldWriteLegacy = target.isNightOfTheZealotCampaign
            && trimmedValue("ARKHAM_LIVE_RESULT_PATH", in: environment) == nil
        let strictAsIfAt = try parseOptionalBool(
            trimmedValue("ARKHAM_LIVE_STRICT_AS_IF_AT", in: environment),
            name: "ARKHAM_LIVE_STRICT_AS_IF_AT"
        ) ?? defaultStrictAsIfAt(for: target)
        let achievements = try parseOptionalBool(
            trimmedValue("ARKHAM_LIVE_ACHIEVEMENTS_ENABLED", in: environment),
            name: "ARKHAM_LIVE_ACHIEVEMENTS_ENABLED"
        ) ?? target.defaultAchievementsEnabled
        let includeTarotReadings = try parseOptionalBool(
            trimmedValue("ARKHAM_LIVE_INCLUDE_TAROT_READINGS", in: environment),
            name: "ARKHAM_LIVE_INCLUDE_TAROT_READINGS"
        ) ?? false
        let ultimatumsAndBoons = try parseUltimatumsAndBoons(in: environment)
        return LivePlaythroughConfiguration(
            target: target,
            difficulty: difficulty,
            campaignVariants: campaignVariantValues(in: environment),
            includeTarotReadings: includeTarotReadings,
            strictAsIfAt: strictAsIfAt,
            ultimatumsAndBoons: ultimatumsAndBoons,
            achievementsEnabled: achievements,
            investigators: investigators,
            resultPath: resultPath,
            shouldWriteLegacyNightOfTheZealotSummary: shouldWriteLegacy
        )
    }

    func campaignOrScenario() throws -> CampaignOrScenario {
        switch target {
        case let .campaign(id):
            try CampaignOrScenario(campaignId: id, scenarioId: nil)
        case let .standaloneScenario(id):
            try CampaignOrScenario(campaignId: nil, scenarioId: id)
        }
    }

    func gameName(for investigator: InvestigatorFixture) -> String {
        "Task 1.20.1 — \(target.displayName) — \(investigator.name)"
    }
}

private enum LiveHarnessConfigurationError: Error, CustomStringConvertible, Equatable {
    case bothCampaignAndScenario
    case noInvestigatorCodes
    case unknownDifficulty(String)
    case unknownInvestigator(String)
    case unknownUltimatumOrBoon(String)
    case invalidBoolean(name: String, value: String)

    var description: String {
        switch self {
        case .bothCampaignAndScenario:
            "set either ARKHAM_LIVE_CAMPAIGN_ID or ARKHAM_LIVE_SCENARIO_ID, not both"
        case .noInvestigatorCodes:
            "ARKHAM_LIVE_INVESTIGATOR_CODES must include at least one investigator code"
        case let .unknownDifficulty(value):
            "unknown ARKHAM_LIVE_DIFFICULTY '\(value)'"
        case let .unknownInvestigator(value):
            "unknown ARKHAM_LIVE_INVESTIGATOR_CODES entry '\(value)'"
        case let .unknownUltimatumOrBoon(value):
            "unknown ARKHAM_LIVE_ULTIMATUMS_AND_BOONS entry '\(value)'"
        case let .invalidBoolean(name, value):
            "\(name) must be one of true/false/1/0/yes/no, got '\(value)'"
        }
    }
}

private func trimmedValue(_ key: String, in environment: [String: String]) -> String? {
    guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty
    else { return nil }
    return value
}

private func parseDifficulty(_ value: String) throws -> RequestDifficulty {
    let normalized = value.lowercased()
    guard let difficulty = RequestDifficulty.allCases.first(where: {
        $0.rawValue.lowercased() == normalized
    }) else { throw LiveHarnessConfigurationError.unknownDifficulty(value) }
    return difficulty
}

private func parseInvestigators(
    _ value: String?, target: PlaythroughTarget
) throws -> [InvestigatorFixture] {
    guard let value else {
        return target.isNightOfTheZealotCampaign
            ? InvestigatorFixture.core
            : [InvestigatorFixture.core[0]]
    }
    let requestedCodes = commaSeparatedValues(value)
    guard !requestedCodes.isEmpty else { throw LiveHarnessConfigurationError.noInvestigatorCodes }
    let fixturesByCode = Dictionary(uniqueKeysWithValues: InvestigatorFixture.core.map {
        ($0.code, $0)
    })
    return try requestedCodes.map { code in
        guard let fixture = fixturesByCode[code] else {
            throw LiveHarnessConfigurationError.unknownInvestigator(code)
        }
        return fixture
    }
}

private func campaignVariantValues(in environment: [String: String]) -> [String] {
    let singular = trimmedValue("ARKHAM_LIVE_CAMPAIGN_VARIANT", in: environment)
        .map(commaSeparatedValues) ?? []
    let plural = trimmedValue("ARKHAM_LIVE_CAMPAIGN_VARIANTS", in: environment)
        .map(commaSeparatedValues) ?? []
    return singular + plural
}

private func parseUltimatumsAndBoons(
    in environment: [String: String]
) throws -> [UltimatumOrBoon] {
    let values = trimmedValue("ARKHAM_LIVE_ULTIMATUMS_AND_BOONS", in: environment)
        .map(commaSeparatedValues) ?? []
    return try values.map { value in
        guard let tag = UltimatumOrBoon(rawValue: value) else {
            throw LiveHarnessConfigurationError.unknownUltimatumOrBoon(value)
        }
        return tag
    }
}

private func parseOptionalBool(_ value: String?, name: String) throws -> Bool? {
    guard let value else { return nil }
    switch value.lowercased() {
    case "1", "true", "yes": return true
    case "0", "false", "no": return false
    default: throw LiveHarnessConfigurationError.invalidBoolean(name: name, value: value)
    }
}

private func commaSeparatedValues(_ rawValue: String) -> [String] {
    rawValue.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

private func slugComponent(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    return value.unicodeScalars.map { scalar in
        allowed.contains(scalar) ? String(scalar) : "-"
    }.joined().lowercased()
}

private func eligibleCoreReplacementDeck(
    originalInvestigatorCode: String,
    killedOrInsaneInvestigatorIDs: Set<String>,
    takenInvestigatorIDs: Set<String>,
    replacementDecksByCode: [String: Deck]
) -> Deck? {
    let originalInvestigatorID = "c\(originalInvestigatorCode)"
    for fixture in InvestigatorFixture.core {
        let candidateID = "c\(fixture.code)"
        guard candidateID != originalInvestigatorID,
              !takenInvestigatorIDs.contains(candidateID),
              !killedOrInsaneInvestigatorIDs.contains(candidateID),
              let deck = replacementDecksByCode[fixture.code]
        else { continue }
        return deck
    }
    return nil
}

private func campaignDeckUpgradeBotSelection(
    promptOwnerID: PlayerID,
    projection: BoardProjection,
    replacementDecksByCode: [String: Deck]
) throws -> SelectedBotAnswer {
    let currentInvestigator = try promptOwnerInvestigator(
        promptOwnerID: promptOwnerID,
        projection: projection
    )
    let currentInvestigatorID = currentInvestigator.id.rawValue.rawValue
    if let replacementDeck = try replacementDeckIfRequired(
        for: currentInvestigator,
        in: projection,
        replacementDecksByCode: replacementDecksByCode
    ) {
        return SelectedBotAnswer(
            answer: .replacementDeck(
                originalInvestigatorID: currentInvestigatorID,
                deck: replacementDeck
            ),
            note: "replace killed or insane investigator with "
                + replacementDeck.investigatorName,
            chosenChoiceKind: nil
        )
    }
    return SelectedBotAnswer(
        answer: .skipDeckUpgrade(investigatorID: currentInvestigatorID),
        note: "continue without upgrading",
        chosenChoiceKind: nil
    )
}

private func promptOwnerInvestigator(
    promptOwnerID: PlayerID,
    projection: BoardProjection
) throws -> BoardInvestigatorNode {
    guard let currentInvestigator = projection.investigators.first(where: {
        $0.playerID == promptOwnerID
    }) else {
        throw PlaythroughError.noPromptOwnerInvestigator(promptOwnerID)
    }
    return currentInvestigator
}

private func replacementDeckIfRequired(
    for currentInvestigator: BoardInvestigatorNode,
    in projection: BoardProjection,
    replacementDecksByCode: [String: Deck]
) throws -> Deck? {
    let currentInvestigatorID = currentInvestigator.id.rawValue.rawValue
    let context = CampaignUpgradeDeckContext.make(
        investigator: currentInvestigator,
        campaignSummary: projection.campaignSummary
    )
    guard context.requiresReplacement else { return nil }
    let takenInvestigatorIDs = Set(projection.investigators.map(\.id.rawValue.rawValue))
    let originalInvestigatorCode = investigatorCode(from: currentInvestigatorID)
    if let deck = eligibleCoreReplacementDeck(
        originalInvestigatorCode: originalInvestigatorCode,
        killedOrInsaneInvestigatorIDs: context.killedOrInsaneInvestigatorIDs,
        takenInvestigatorIDs: takenInvestigatorIDs,
        replacementDecksByCode: replacementDecksByCode
    ) {
        return deck
    }
    throw PlaythroughError.noEligibleReplacementInvestigator(currentInvestigatorID)
}

private func investigatorCode(from investigatorID: String) -> String {
    investigatorID.hasPrefix("c") ? String(investigatorID.dropFirst()) : investigatorID
}

@MainActor
@Suite("Live campaign playthrough")
// swiftlint:disable:next type_body_length
struct LiveNightOfTheZealotPlaythroughTests {
    private static func tracePath(
        for investigator: InvestigatorFixture,
        configuration: LivePlaythroughConfiguration
    ) -> String {
        "/tmp/arkham-logs/playthrough-trace-\(configuration.target.slug)-"
            + "\(investigator.traceSlug).jsonl"
    }

    @Test("Live harness defaults to Night of the Zealot for every core investigator")
    func defaultConfigurationPreservesNightOfTheZealotRun() throws {
        let configuration = try LivePlaythroughConfiguration.fromEnvironment([:])
        #expect(configuration.target == .campaign(id: "01"))
        #expect(configuration.difficulty == .easy)
        #expect(configuration.investigators.map(\.code) == InvestigatorFixture.core.map(\.code))
        #expect(configuration.strictAsIfAtField == .value(false))
        #expect(configuration.asIfRulingField == .value(.chapter1))
        #expect(configuration.achievementsEnabled == true)
    }

    @Test("Live harness accepts a standalone scenario target")
    func standaloneScenarioConfiguration() throws {
        let configuration = try LivePlaythroughConfiguration.fromEnvironment([
            "ARKHAM_LIVE_SCENARIO_ID": "50001",
            "ARKHAM_LIVE_DIFFICULTY": "Standard",
            "ARKHAM_LIVE_INVESTIGATOR_CODES": "01001",
        ])
        #expect(configuration.target == .standaloneScenario(id: "50001"))
        #expect(configuration.difficulty == .standard)
        #expect(configuration.investigators.map(\.code) == ["01001"])
        #expect(configuration.strictAsIfAtField == .value(false))
        #expect(configuration.asIfRulingField == .value(.chapter1))
        #expect(configuration.achievementsEnabled == false)
    }

    @Test("Live harness maps web variants and as-if ruling fields")
    func campaignVariantsAndAsIfRulingMapToWebFields() throws {
        let configuration = try LivePlaythroughConfiguration.fromEnvironment([
            "ARKHAM_LIVE_CAMPAIGN_ID": "11",
            "ARKHAM_LIVE_CAMPAIGN_VARIANT": "alpha, beta",
            "ARKHAM_LIVE_CAMPAIGN_VARIANTS": "gamma",
            "ARKHAM_LIVE_STRICT_AS_IF_AT": "false",
        ])

        #expect(configuration.options == [
            .campaignVariant("alpha"),
            .campaignVariant("beta"),
            .campaignVariant("gamma"),
        ])
        #expect(configuration.strictAsIfAtField == .value(false))
        #expect(configuration.asIfRulingField == .value(.chapter1))
    }

    @Test("Return To campaigns inherit the web base-campaign as-if chapter")
    func returnToCampaignUsesBaseCampaignChapter() throws {
        let configuration = try LivePlaythroughConfiguration.fromEnvironment([
            "ARKHAM_LIVE_CAMPAIGN_ID": "50",
        ])

        #expect(configuration.target == .campaign(id: "50"))
        #expect(configuration.strictAsIfAtField == .value(false))
        #expect(configuration.asIfRulingField == .value(.chapter1))
    }

    @Test("Chapter 2 standalone scenarios inherit their web campaign chapter")
    func chapter2StandaloneScenarioUsesCampaignChapter() throws {
        let configuration = try LivePlaythroughConfiguration.fromEnvironment([
            "ARKHAM_LIVE_SCENARIO_ID": "11501",
            "ARKHAM_LIVE_INVESTIGATOR_CODES": "01001",
        ])

        #expect(configuration.target == .standaloneScenario(id: "11501"))
        #expect(configuration.strictAsIfAtField == .value(true))
        #expect(configuration.asIfRulingField == .value(.chapter2))
    }

    @Test("Return To standalone scenarios inherit the web base-campaign chapter")
    func returnToStandaloneScenarioUsesBaseCampaignChapter() throws {
        let configuration = try LivePlaythroughConfiguration.fromEnvironment([
            "ARKHAM_LIVE_SCENARIO_ID": "50011",
            "ARKHAM_LIVE_INVESTIGATOR_CODES": "01001",
        ])

        #expect(configuration.target == .standaloneScenario(id: "50011"))
        #expect(configuration.strictAsIfAtField == .value(false))
        #expect(configuration.asIfRulingField == .value(.chapter1))
    }

    @Test("Live harness rejects mutually exclusive target settings")
    func campaignAndScenarioBothSetIsConfigurationError() {
        #expect(throws: LiveHarnessConfigurationError.bothCampaignAndScenario) {
            _ = try LivePlaythroughConfiguration.fromEnvironment([
                "ARKHAM_LIVE_CAMPAIGN_ID": "01",
                "ARKHAM_LIVE_SCENARIO_ID": "01104",
            ])
        }
    }

    @Test("Live harness rejects invalid boolean settings")
    func invalidBooleanIsConfigurationError() {
        #expect(throws: LiveHarnessConfigurationError.invalidBoolean(
            name: "ARKHAM_LIVE_STRICT_AS_IF_AT",
            value: "sometimes"
        )) {
            _ = try LivePlaythroughConfiguration.fromEnvironment([
                "ARKHAM_LIVE_STRICT_AS_IF_AT": "sometimes",
            ])
        }
    }

    @Test("Live harness rejects empty explicit investigator lists")
    func emptyExplicitInvestigatorListIsConfigurationError() {
        #expect(throws: LiveHarnessConfigurationError.noInvestigatorCodes) {
            _ = try LivePlaythroughConfiguration.fromEnvironment([
                "ARKHAM_LIVE_INVESTIGATOR_CODES": ", , ",
            ])
        }
    }

    @Test("Live harness chooses first untaken non-killed core replacement deck")
    func replacementDeckSelectionSkipsTakenKilledAndInsaneInvestigators() throws {
        let decks = try Dictionary(uniqueKeysWithValues: InvestigatorFixture.core.map {
            try ($0.code, Self.deckFixture(for: $0))
        })

        let selected = eligibleCoreReplacementDeck(
            originalInvestigatorCode: "01001",
            killedOrInsaneInvestigatorIDs: ["c01001", "c01002"],
            takenInvestigatorIDs: ["c01001", "c01003"],
            replacementDecksByCode: decks
        )

        #expect(selected?.playableList.investigatorCode.rawValue == "c01004")
    }

    @Test("Live harness reports when no core replacement deck is eligible")
    func replacementDeckSelectionReturnsNilWhenNoCoreInvestigatorIsEligible() throws {
        let decks = try Dictionary(uniqueKeysWithValues: InvestigatorFixture.core.map {
            try ($0.code, Self.deckFixture(for: $0))
        })
        let unavailable = Set(InvestigatorFixture.core.map { "c\($0.code)" })

        let selected = eligibleCoreReplacementDeck(
            originalInvestigatorCode: "01001",
            killedOrInsaneInvestigatorIDs: unavailable,
            takenInvestigatorIDs: [],
            replacementDecksByCode: decks
        )

        #expect(selected == nil)
    }

    @Test("Live harness submits replacements for the prompt owner's current investigator")
    func deckUpgradeReplacementUsesCurrentSeatInvestigator() throws {
        let ownerID = PlayerID(UUID())
        let currentInvestigatorID = try InvestigatorID(CardCode("c01002"))
        let projection = try Self.campaignDeckUpgradeProjection(
            ownerID: ownerID,
            currentInvestigatorID: currentInvestigatorID,
            killedOrInsaneInvestigatorIDs: ["c01002"]
        )
        let decks = try Dictionary(uniqueKeysWithValues: InvestigatorFixture.core.map {
            try ($0.code, Self.deckFixture(for: $0))
        })

        let selected = try campaignDeckUpgradeBotSelection(
            promptOwnerID: ownerID,
            projection: projection,
            replacementDecksByCode: decks
        )

        guard case let .replacementDeck(originalInvestigatorID, deck) = selected.answer else {
            Issue.record("Expected a replacement deck selection")
            return
        }
        #expect(originalInvestigatorID == "c01002")
        #expect(deck.playableList.investigatorCode.rawValue == "c01001")
    }

    @Test("Live harness skips upgrades with the prompt owner's current investigator")
    func deckUpgradeSkipUsesCurrentSeatInvestigator() throws {
        let ownerID = PlayerID(UUID())
        let currentInvestigatorID = try InvestigatorID(CardCode("c01002"))
        let projection = try Self.campaignDeckUpgradeProjection(
            ownerID: ownerID,
            currentInvestigatorID: currentInvestigatorID,
            killedOrInsaneInvestigatorIDs: ["c01001"]
        )

        let selected = try campaignDeckUpgradeBotSelection(
            promptOwnerID: ownerID,
            projection: projection,
            replacementDecksByCode: [:]
        )

        guard case let .skipDeckUpgrade(investigatorID) = selected.answer else {
            Issue.record("Expected a deck-upgrade skip")
            return
        }
        #expect(investigatorID == "c01002")
    }

    @Test("Live harness rejects unknown investigators and ultimatum values")
    func unknownInvestigatorAndUltimatumAreConfigurationErrors() {
        #expect(throws: LiveHarnessConfigurationError.unknownInvestigator("99999")) {
            _ = try LivePlaythroughConfiguration.fromEnvironment([
                "ARKHAM_LIVE_INVESTIGATOR_CODES": "99999",
            ])
        }
        #expect(throws: LiveHarnessConfigurationError.unknownUltimatumOrBoon("Bogus")) {
            _ = try LivePlaythroughConfiguration.fromEnvironment([
                "ARKHAM_LIVE_ULTIMATUMS_AND_BOONS": "BoonOfHades, Bogus",
            ])
        }
    }

    private static func deckFixture(for investigator: InvestigatorFixture) throws -> Deck {
        let slots = try Dictionary(uniqueKeysWithValues: investigator.deckSlots.map {
            try (CardCode("c\($0.key)"), $0.value)
        })
        let deckList = try DeckList(
            slots: CardQuantityMap(slots),
            sideSlots: CardQuantityMap([:]),
            investigatorCode: CardCode("c\(investigator.code)"),
            investigatorName: investigator.name,
            meta: nil,
            tabooId: nil,
            url: nil,
            id: investigator.code,
            name: "\(investigator.name) replacement"
        )
        return Deck(
            id: DeckID(UUID()),
            userId: 1,
            url: nil,
            name: "\(investigator.name) replacement",
            investigatorName: investigator.name,
            list: deckList
        )
    }

    private static func campaignDeckUpgradeProjection(
        ownerID: PlayerID,
        currentInvestigatorID: InvestigatorID,
        killedOrInsaneInvestigatorIDs: [String]
    ) throws -> BoardProjection {
        let currentInvestigator = BoardTestFixtures.investigator(
            id: currentInvestigatorID,
            playerID: ownerID
        )
        let snapshot = BoardTestFixtures.snapshot(
            mode: .campaignOnly(campaignLogFixture(killedOrInsaneInvestigatorIDs)),
            investigators: [currentInvestigatorID: currentInvestigator],
            playerOrder: [currentInvestigatorID],
            activeInvestigatorID: currentInvestigatorID,
            leadInvestigatorID: currentInvestigatorID
        )
        return BoardProjectionBuilder.makeProjection(from: snapshot)
    }

    private static func campaignLogFixture(_ killedOrInsaneInvestigatorIDs: [String]) -> JSONValue {
        .object([
            "log": .object([
                "recorded": .array([]),
                "crossedOut": .array([]),
                "recordedCounts": .array([]),
                "recordedSets": .array([
                    .array([
                        .object(["tag": .string("KilledInvestigators")]),
                        .array(killedOrInsaneInvestigatorIDs.map { .string($0) }),
                    ]),
                ]),
            ]),
        ])
    }

    @Test("Campaign outcome helpers preserve step order and resolution mappings")
    // swiftlint:disable:next function_body_length
    func campaignOutcomeHelpersPreserveStepOrderAndResolutionMappings() {
        let completedSteps: JSONValue = .array([
            .object([
                "tag": .string("ScenarioStep"),
                "contents": .string("c02062"),
            ]),
            .object([
                "tag": .string("InterludeStep"),
                "contents": .string("ignored"),
            ]),
            .object([
                "tag": .string("StandaloneScenarioStep"),
                "contents": .array([
                    .string("c81001"),
                    .object(["mode": .string("standalone")]),
                ]),
            ]),
            .object([
                "tag": .string("ScenarioStepWithOptions"),
                "contents": .array([
                    .string("c01104"),
                    .object(["difficulty": .string("Easy")]),
                ]),
            ]),
        ])
        let resolutions: [String: JSONValue] = [
            "01104": .string("NoResolution"),
            "c81001": .string("StandaloneResolution"),
            "c02062": .array([.string("R1"), .string("R2")]),
            "c99999": .string("UnmatchedResolution"),
        ]
        let campaign: JSONValue = .object([
            "completedSteps": completedSteps,
            "resolutions": .object(resolutions),
        ])

        #expect(campaignStepScenarioIDs(in: completedSteps) == [
            "c01104",
            "c81001",
            "c02062",
        ])
        #expect(campaignStepScenarioID(.object([
            "tag": .string("StandaloneScenarioStep"),
            "contents": .array([.string("c81001"), .object([:])]),
        ])) == "c81001")
        let strippedPrefixEntry = resolutionEntry(for: "c01104", in: resolutions)
        #expect(strippedPrefixEntry?.key == "01104")
        #expect(strippedPrefixEntry?.value == .string("NoResolution"))
        let addedPrefixEntry = resolutionEntry(for: "02062", in: resolutions)
        #expect(addedPrefixEntry?.key == "c02062")
        #expect(addedPrefixEntry?.value == .array([.string("R1"), .string("R2")]))

        let outcomes = campaignScenarioOutcomes(from: campaign)
        #expect(outcomes["c01104"] == "resolution \(jsonString(.string("NoResolution")))")
        #expect(outcomes["c81001"] == "resolution \(jsonString(.string("StandaloneResolution")))")
        let arrayResolution = jsonString(.array([.string("R1"), .string("R2")]))
        #expect(outcomes["c02062"] == "resolution \(arrayResolution)")
        #expect(outcomes["c99999"] == "resolution \(jsonString(.string("UnmatchedResolution")))")
    }

    @Test("Scenario-only outcome helpers distinguish non-terminal from terminal")
    func scenarioOnlyOutcomeHelpersDistinguishTerminalFallback() throws {
        let scenarioOnlyMode = try liveHarnessScenarioOnlyMode()
        let scenarioID = try scenarioID(in: scenarioOnlyMode)

        #expect(scenarioOutcomes(from: scenarioOnlyMode) == [:])
        #expect(terminalScenarioOutcomes(from: scenarioOnlyMode) == [
            scenarioID: "gameState IsOver",
        ])
    }

    @Test("Campaign-scenario outcome helpers distinguish non-terminal from terminal")
    func campaignScenarioOutcomeHelpersDistinguishTerminalFallback() throws {
        let mode = try liveHarnessGameModeFixture(named: "mode-campaign-scenario")
        let scenarioID = try scenarioID(in: mode)

        #expect(scenarioOutcomes(from: mode) == [:])
        #expect(terminalScenarioOutcomes(from: mode) == [
            scenarioID: "gameState IsOver",
        ])
    }

    @Test(
        "Env-gated solo live playthroughs",
        .enabled(if: liveServerURLForPlaythrough() != nil)
    )
    func configuredLivePlaythroughs() async throws {
        let rawURL = try #require(liveServerURLForPlaythrough())
        let configuration = try LivePlaythroughConfiguration.fromEnvironment()

        let profile = try ServerProfile.custom(
            displayName: "Task 1.20.1 live server",
            rawURL: rawURL
        )
        var results: [PlaythroughResult] = []
        try writeResults(
            results,
            configuration: configuration,
            note: "Started \(configuration.target.displayName) live playthroughs "
                + "against \(profile.endpointSummary)."
        )

        for investigator in configuration.investigators {
            let result = await runInvestigator(
                investigator, on: profile, configuration: configuration
            )
            results.append(result)
            try writeResults(
                results,
                configuration: configuration,
                note: "Recorded \(investigator.name)."
            )
        }

        try writeResults(
            results,
            configuration: configuration,
            note: "Finished live playthrough run."
        )
        #expect(!results.isEmpty)
        for result in results {
            switch result.status {
            case .passed:
                continue
            case let .failed(reason):
                Issue.record("\(result.investigator.name) failed: \(reason)")
            }
        }
        let allPassed = results.allSatisfy(\.status.isPassed)
        #expect(allPassed)
    }

    // swiftlint:disable:next function_body_length
    private func runInvestigator(
        _ investigator: InvestigatorFixture,
        on profile: ServerProfile,
        configuration: LivePlaythroughConfiguration
    ) async -> PlaythroughResult {
        var scenarioOutcomes: [String: String] = [:]
        var promptFailure: PromptFailure?
        do {
            let model = AppModel(
                profileStore: FakeServerProfileStore(
                    profiles: [profile], selectedID: profile.id
                ),
                tokenStore: FakeTokenStore(),
                cleanupPendingStore: FakeTokenCleanupPendingStore()
            )
            try await prepareSignedInSession(model: model, investigator: investigator)
            try await waitForLocaleCatalogIfAdvertised(model)
            try await loadCardCatalog(model)

            guard case let .signedIn(signedInProfile, _, _) = model.sessionState else {
                throw PlaythroughError.notSignedIn(String(describing: model.sessionState))
            }
            let token = try await model.currentGameLifecycleToken(for: signedInProfile)
            let deckService = DeckService()
            let lifecycle = GameLifecycleService()
            let deck = try await deckService.createDeck(
                investigator.createDeckRequest,
                on: signedInProfile,
                token: token
            )
            let replacementDecksByCode = try await createReplacementDecks(
                excluding: investigator,
                deckService: deckService,
                profile: signedInProfile,
                token: token
            )
            let campaignOrScenario = try configuration.campaignOrScenario()
            let gameID = try await model.createGame(
                CreateGameRequest(
                    deckIds: [deck.id],
                    playerCount: 1,
                    campaignOrScenario: campaignOrScenario,
                    difficulty: configuration.difficulty,
                    campaignName: configuration.gameName(for: investigator),
                    multiplayerVariant: .solo,
                    includeTarotReadings: configuration.includeTarotReadings,
                    options: configuration.options,
                    strictAsIfAt: configuration.strictAsIfAtField,
                    asIfRuling: configuration.asIfRulingField,
                    ultimatumsAndBoons: configuration.ultimatumsAndBoonsField,
                    achievementsEnabled: .value(configuration.achievementsEnabled)
                )
            )

            let subscription = model.subscribeToLiveGame(gameID)
            defer { model.unsubscribeFromLiveGame(subscription) }

            let trace = PlaythroughTraceRecorder(
                path: Self.tracePath(for: investigator, configuration: configuration)
            )
            try trace.reset()
            let bot = LivePlaythroughBot(
                model: model,
                lifecycle: lifecycle,
                profile: signedInProfile,
                token: token,
                gameID: gameID,
                investigator: investigator,
                deck: deck,
                replacementDecksByCode: replacementDecksByCode,
                trace: trace,
                diagnosticBypassUnsupported: Self.diagnosticBypassUnsupported
            )
            let outcome = try await bot.driveUntilServerCompletion()
            scenarioOutcomes = outcome.scenarioOutcomes
            promptFailure = outcome.promptFailure
            if outcome.reachedServerCompletion {
                return PlaythroughResult(
                    investigator: investigator,
                    status: .passed,
                    scenarioOutcomes: scenarioOutcomes,
                    promptFailure: nil,
                    finalGameID: gameID.rawValue.uuidString.lowercased()
                )
            }
            let reason = promptFailure?.description
                ?? "playthrough stopped without server gameState IsOver"
            return PlaythroughResult(
                investigator: investigator,
                status: .failed(reason),
                scenarioOutcomes: scenarioOutcomes,
                promptFailure: promptFailure,
                finalGameID: gameID.rawValue.uuidString.lowercased()
            )
        } catch {
            return PlaythroughResult(
                investigator: investigator,
                status: .failed(String(describing: error)),
                scenarioOutcomes: scenarioOutcomes,
                promptFailure: promptFailure,
                finalGameID: nil
            )
        }
    }

    private func createReplacementDecks(
        excluding investigator: InvestigatorFixture,
        deckService: DeckService,
        profile: ServerProfile,
        token: String
    ) async throws -> [String: Deck] {
        var decks: [String: Deck] = [:]
        for fixture in InvestigatorFixture.core where fixture.code != investigator.code {
            decks[fixture.code] = try await deckService.createDeck(
                fixture.createDeckRequest,
                on: profile,
                token: token
            )
        }
        return decks
    }

    private func prepareSignedInSession(
        model: AppModel,
        investigator: InvestigatorFixture
    ) async throws {
        await model.flowTask?.value
        guard case .signedOut = model.sessionState else {
            throw PlaythroughError.notSignedOut(String(describing: model.sessionState))
        }
        let suffix = UUID().uuidString.lowercased()
        let details = RegistrationDetails(
            email: "task-1-20-1-\(investigator.code)-\(suffix)@example.test",
            username: "task-1-20-1-\(investigator.code)-\(suffix.prefix(8))",
            password: "task-1-20-1-password"
        )
        guard model.register(details) != nil else {
            throw PlaythroughError.registrationDidNotStart
        }
        try await waitUntil(timeout: 30, description: "registration completes") {
            model.operation == .idle
        }
        guard case .signedIn = model.sessionState else {
            throw PlaythroughError.notSignedIn(String(describing: model.sessionState))
        }
    }

    private static var diagnosticBypassUnsupported: Bool {
        let rawValue = ProcessInfo.processInfo
            .environment["ARKHAM_LIVE_DIAGNOSTIC_BYPASS_UNSUPPORTED"]?
            .lowercased()
        return rawValue == "1" || rawValue == "true" || rawValue == "yes"
    }

    private func waitForLocaleCatalogIfAdvertised(_ model: AppModel) async throws {
        guard model.localeCatalogRequest != nil || model.isLocaleCatalogLoading else { return }
        try await waitUntil(timeout: 30, description: "locale catalog loads or fails") {
            !model.isLocaleCatalogLoading
        }
    }

    private func loadCardCatalog(_ model: AppModel) async throws {
        model.loadCardCatalogIfNeeded()
        try await waitUntil(timeout: 60, description: "card catalog loads or fails") {
            !model.isCardCatalogLoading
        }
        if let failure = model.cardCatalogFailure {
            throw PlaythroughError.cardCatalogUnavailable("card catalog failed: \(failure)")
        }
        guard model.cardCatalog != nil else {
            throw PlaythroughError.cardCatalogUnavailable(
                "card catalog finished without a snapshot"
            )
        }
    }

    // swiftlint:disable:next function_body_length
    private func writeResults(
        _ results: [PlaythroughResult],
        configuration: LivePlaythroughConfiguration,
        note: String
    ) throws {
        let fileManager = FileManager.default
        let resultDirectory = URL(fileURLWithPath: configuration.resultPath)
            .deletingLastPathComponent()
        try fileManager.createDirectory(
            at: resultDirectory, withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            atPath: "/tmp/arkham-logs", withIntermediateDirectories: true
        )
        let scenarioColumns = scenarioOutcomeColumns(in: results)
        let variantsSummary = configuration.campaignVariants.isEmpty
            ? "none"
            : configuration.campaignVariants.joined(separator: ", ")
        var lines: [String] = [
            "# \(configuration.target.displayName) live playthrough results",
            "",
            "\(note)",
            "",
            "Target: \(configuration.target.summary)",
            "Difficulty: \(configuration.difficulty.rawValue)",
            "Campaign variants: \(variantsSummary)",
            "Diagnostic bypass: \(Self.diagnosticBypassUnsupported ? "enabled" : "disabled")",
            "",
            resultHeader(for: scenarioColumns),
            resultSeparator(for: scenarioColumns),
        ]
        for result in results {
            let failure = result.promptFailure?.markdownSummary ?? "—"
            let game = result.finalGameID ?? "—"
            let cells = scenarioColumns.map { key in
                result.scenarioOutcomes[key]?.replacingOccurrences(of: "|", with: "\\|")
                    ?? "not observed"
            }
            lines.append(
                ([
                    "\(result.investigator.name) (\(result.investigator.code))",
                    result.status.tableText,
                ] + cells + [failure, game])
                    .joined(separator: " | ")
                    .withMarkdownTablePipes()
            )
        }
        lines.append("")
        lines.append("Trace files: /tmp/arkham-logs/playthrough-trace-"
            + "\(configuration.target.slug)-<investigator>.jsonl")
        lines.append("Generated: \(Date())")
        let body = lines.joined(separator: "\n")
        try body.write(
            toFile: configuration.resultPath, atomically: true, encoding: .utf8
        )
        if configuration.shouldWriteLegacyNightOfTheZealotSummary {
            try body.write(
                toFile: "/tmp/arkham-logs/playthrough-results.md",
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private func scenarioOutcomeColumns(in results: [PlaythroughResult]) -> [String] {
        Array(Set(results.flatMap(\.scenarioOutcomes.keys))).sorted()
    }

    private func resultHeader(for scenarioColumns: [String]) -> String {
        (["Investigator", "Status"] + scenarioColumns.map { "Scenario \($0)" }
            + ["Failing prompt", "Game"])
            .joined(separator: " | ")
            .withMarkdownTablePipes()
    }

    private func resultSeparator(for scenarioColumns: [String]) -> String {
        Array(repeating: "---", count: scenarioColumns.count + 4)
            .joined(separator: " | ")
            .withMarkdownTablePipes()
    }
}

@MainActor
// swiftlint:disable:next type_body_length
private struct LivePlaythroughBot {
    let model: AppModel
    let lifecycle: GameLifecycleService
    let profile: ServerProfile
    let token: String
    let gameID: GameID
    let investigator: InvestigatorFixture
    let deck: Deck
    let replacementDecksByCode: [String: Deck]
    let trace: PlaythroughTraceRecorder
    let diagnosticBypassUnsupported: Bool

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func driveUntilServerCompletion() async throws -> BotOutcome {
        var repeatedQuestionShapes: [String: Int] = [:]
        var startSkillTestPreparationCounts: [String: Int] = [:]
        let startedAt = Date()
        let timeout = ProcessInfo.processInfo.environment["ARKHAM_LIVE_PLAYTHROUGH_TIMEOUT"]
            .flatMap(TimeInterval.init) ?? 900
        try trace.append(.runStarted(investigator: investigator, gameID: gameID))
        while Date().timeIntervalSince(startedAt) < timeout {
            let envelope = try await lifecycle.getGame(gameID, on: profile, token: token)
            let currentOutcomes = scenarioOutcomes(from: envelope.game)
            if envelope.game.gameState == .over {
                let currentOutcomes = terminalScenarioOutcomes(from: envelope.game)
                try trace.append(.runFinished(
                    investigator: investigator,
                    gameID: gameID,
                    reachedServerCompletion: true,
                    scenarioOutcomes: currentOutcomes
                ))
                return BotOutcome(
                    reachedServerCompletion: true,
                    scenarioOutcomes: currentOutcomes,
                    promptFailure: nil
                )
            }

            let projection: BoardProjection
            do {
                projection = try await waitForProjection()
            } catch let error as PlaythroughError {
                guard case .timedOut = error else { throw error }
                return try recordRunTimedOut(
                    reason: error.description,
                    snapshot: envelope.game,
                    scenarioOutcomes: currentOutcomes
                )
            }
            guard let prompt = model.basicChoicePresentation(for: gameID) else {
                try await Task.sleep(for: .milliseconds(200))
                continue
            }
            let scenario = currentScenarioCode(projection: projection, snapshot: envelope.game)
            try await captureReplacementPromptIfRequested(prompt: prompt, projection: projection)
            let repeatKey = coverageRepeatKey(scenario: scenario, prompt: prompt)
            let repeatCount = repeatedQuestionShapes[repeatKey, default: 0]
            let skillTestPreparationKey = skillTestPreparationLoopKey(
                scenario: scenario,
                prompt: prompt
            )
            let skillTestPreparationCount = skillTestPreparationKey.map {
                startSkillTestPreparationCounts[$0, default: 0]
            } ?? 0
            let cannotRender = !prompt.isRenderableQuestion
                && !isInitialChooseDeckPrompt(prompt)
                && !prompt.isChooseUpgradeDeckPrompt
                && !canDiagnosticBypassUnsupported(prompt)
            if cannotRender {
                let failure = PromptFailure(
                    scenario: scenario,
                    investigator: investigator,
                    questionVersion: prompt.questionVersion,
                    rawQuestionTag: describeRawQuestionTag(prompt.identity.rawQuestion),
                    reason: "prompt is not renderable by this app version"
                )
                try trace.append(.prompt(
                    investigator: investigator,
                    gameID: gameID,
                    scenario: scenario,
                    prompt: prompt,
                    projection: projection,
                    repeatCount: repeatCount,
                    selectedAnswer: nil,
                    submission: nil,
                    outcome: .failed(failure.reason),
                    serverFeedback: serverFeedbackSummary()
                ))
                return BotOutcome(
                    reachedServerCompletion: false,
                    scenarioOutcomes: currentOutcomes,
                    promptFailure: failure
                )
            }
            let cannotAnswer = !prompt.canSubmit
                && !prompt.isChooseUpgradeDeckPrompt
                && !isInitialChooseDeckPrompt(prompt)
                && !canDiagnosticBypassUnsupported(prompt)
            if cannotAnswer {
                let failure = PromptFailure(
                    scenario: scenario,
                    investigator: investigator,
                    questionVersion: prompt.questionVersion,
                    rawQuestionTag: describeRawQuestionTag(prompt.identity.rawQuestion),
                    reason: prompt.statusMessage ?? "prompt is not answerable"
                )
                try trace.append(.prompt(
                    investigator: investigator,
                    gameID: gameID,
                    scenario: scenario,
                    prompt: prompt,
                    projection: projection,
                    repeatCount: repeatCount,
                    selectedAnswer: nil,
                    submission: nil,
                    outcome: .failed(failure.reason),
                    serverFeedback: serverFeedbackSummary()
                ))
                return BotOutcome(
                    reachedServerCompletion: false,
                    scenarioOutcomes: currentOutcomes,
                    promptFailure: failure
                )
            }

            let selectedAnswer: SelectedBotAnswer
            do {
                selectedAnswer = try selectAnswer(
                    prompt: prompt,
                    projection: projection,
                    repeatCount: repeatCount,
                    skillTestPreparationCount: skillTestPreparationCount
                )
            } catch let error as PlaythroughError {
                let failure = PromptFailure(
                    scenario: scenario,
                    investigator: investigator,
                    questionVersion: prompt.questionVersion,
                    rawQuestionTag: describeRawQuestionTag(prompt.identity.rawQuestion),
                    reason: error.description
                )
                try trace.append(.prompt(
                    investigator: investigator,
                    gameID: gameID,
                    scenario: scenario,
                    prompt: prompt,
                    projection: projection,
                    repeatCount: repeatCount,
                    selectedAnswer: nil,
                    submission: nil,
                    outcome: .failed(failure.reason),
                    serverFeedback: serverFeedbackSummary()
                ))
                return BotOutcome(
                    reachedServerCompletion: false,
                    scenarioOutcomes: currentOutcomes,
                    promptFailure: failure
                )
            }

            let submission = try selectedAnswer.answer.traceSubmission(prompt: prompt)
            do {
                let seatInvestigatorBeforeReplacement: SeatInvestigatorIdentity? =
                    if case .replacementDeck = selectedAnswer.answer {
                        seatInvestigatorIdentity(
                            for: prompt.identity.ownerID,
                            in: projection
                        )
                    } else {
                        nil
                    }
                let submitOutcome = try await submit(selectedAnswer.answer, prompt: prompt)
                let advanced = try await waitForPromptAdvance(
                    from: prompt.identity,
                    acceptingSeatInvestigatorChangeFrom: seatInvestigatorBeforeReplacement
                )
                let feedback = serverFeedbackSummary()
                if advanced {
                    try trace.append(.prompt(
                        investigator: investigator,
                        gameID: gameID,
                        scenario: scenario,
                        prompt: prompt,
                        projection: projection,
                        repeatCount: repeatCount,
                        selectedAnswer: selectedAnswer,
                        submission: submission,
                        outcome: .submittedAndAdvanced(submitOutcome.detail),
                        serverFeedback: feedback,
                        diagnosticBypass: submitOutcome.diagnosticBypass
                    ))
                    repeatedQuestionShapes[repeatKey] = repeatCount + 1
                    if let skillTestPreparationKey {
                        startSkillTestPreparationCounts[skillTestPreparationKey] =
                            skillTestPreparationCount + 1
                    }
                } else {
                    let reason = [
                        "same prompt remained after the bot answered it",
                        feedback?.description,
                    ].compactMap(\.self).joined(separator: "; ")
                    let failure = PromptFailure(
                        scenario: scenario,
                        investigator: investigator,
                        questionVersion: prompt.questionVersion,
                        rawQuestionTag: describeRawQuestionTag(prompt.identity.rawQuestion),
                        reason: reason
                    )
                    try trace.append(.prompt(
                        investigator: investigator,
                        gameID: gameID,
                        scenario: scenario,
                        prompt: prompt,
                        projection: projection,
                        repeatCount: repeatCount,
                        selectedAnswer: selectedAnswer,
                        submission: submission,
                        outcome: .failed(failure.reason),
                        serverFeedback: feedback,
                        diagnosticBypass: submitOutcome.diagnosticBypass
                    ))
                    return BotOutcome(
                        reachedServerCompletion: false,
                        scenarioOutcomes: currentOutcomes,
                        promptFailure: failure
                    )
                }
            } catch let error as PlaythroughError {
                let failure = PromptFailure(
                    scenario: scenario,
                    investigator: investigator,
                    questionVersion: prompt.questionVersion,
                    rawQuestionTag: describeRawQuestionTag(prompt.identity.rawQuestion),
                    reason: error.description
                )
                try trace.append(.prompt(
                    investigator: investigator,
                    gameID: gameID,
                    scenario: scenario,
                    prompt: prompt,
                    projection: projection,
                    repeatCount: repeatCount,
                    selectedAnswer: selectedAnswer,
                    submission: submission,
                    outcome: .failed(failure.reason),
                    serverFeedback: serverFeedbackSummary()
                ))
                return BotOutcome(
                    reachedServerCompletion: false,
                    scenarioOutcomes: currentOutcomes,
                    promptFailure: failure
                )
            }
        }
        let envelope = try await lifecycle.getGame(gameID, on: profile, token: token)
        let currentOutcomes = scenarioOutcomes(from: envelope.game)
        return try recordRunTimedOut(
            reason: "playthrough timed out before server gameState IsOver",
            snapshot: envelope.game,
            scenarioOutcomes: currentOutcomes
        )
    }

    private func waitForProjection() async throws -> BoardProjection {
        try await waitForValue(timeout: 20, description: "live projection") {
            model.liveGameState(for: gameID).lastKnownProjection
        }
    }

    private func recordRunTimedOut(
        reason: String,
        snapshot: PublicGameSnapshot,
        scenarioOutcomes: [String: String]
    ) throws -> BotOutcome {
        let prompt = model.basicChoicePresentation(for: gameID)
        let failure = PromptFailure(
            scenario: currentScenarioCode(
                projection: model.liveGameState(for: gameID).lastKnownProjection,
                snapshot: snapshot
            ),
            investigator: investigator,
            questionVersion: prompt?.questionVersion ?? -1,
            rawQuestionTag: prompt.map {
                describeRawQuestionTag($0.identity.rawQuestion)
            } ?? "none",
            reason: reason
        )
        try trace.append(.runTimedOut(
            investigator: investigator,
            gameID: gameID,
            failure: failure,
            scenarioOutcomes: scenarioOutcomes
        ))
        return BotOutcome(
            reachedServerCompletion: false,
            scenarioOutcomes: scenarioOutcomes,
            promptFailure: failure
        )
    }

    private func serverFeedbackSummary() -> TraceServerFeedback? {
        guard let message = model.basicChoiceServerFeedback[gameID] else { return nil }
        let source = switch model.basicChoiceServerFeedbackSources[gameID] {
        case .answerRejected?: "AnswerRejected"
        case .gameError?: "GameError"
        case nil: "unknown"
        }
        return TraceServerFeedback(source: source, message: message)
    }

    // swiftlint:disable:next function_body_length
    private func selectAnswer(
        prompt: BasicChoicePromptPresentation,
        projection: BoardProjection,
        repeatCount: Int,
        skillTestPreparationCount: Int
    ) throws -> SelectedBotAnswer {
        if isInitialChooseDeckPrompt(prompt) {
            return SelectedBotAnswer(
                answer: .savedDeck(deck), note: "starter deck", chosenChoiceKind: nil
            )
        }
        if prompt.isChooseUpgradeDeckPrompt {
            return try campaignDeckUpgradeBotSelection(
                promptOwnerID: prompt.identity.ownerID,
                projection: projection,
                replacementDecksByCode: replacementDecksByCode
            )
        }
        if let continuation = projection.campaignContinuation, isContinueCampaignPrompt(prompt) {
            return SelectedBotAnswer(
                answer: .continueCampaign(continuation.nextStep),
                note: "continue with current server campaign step",
                chosenChoiceKind: nil
            )
        }
        if let amountPrompt = prompt.amountPrompt(in: projection) {
            return switch amountPrompt.kind {
            case .amounts:
                SelectedBotAnswer(
                    answer: .amounts(minimumAmounts(for: amountPrompt)),
                    note: "minimum legal amounts",
                    chosenChoiceKind: nil
                )
            case .payment:
                SelectedBotAnswer(
                    answer: .paymentAmounts(minimumAmounts(for: amountPrompt)),
                    note: "minimum legal payment amounts",
                    chosenChoiceKind: nil
                )
            }
        }
        if prompt.exchangePrompt(in: projection) != nil {
            return SelectedBotAnswer(
                answer: .exchangeAmount(0), note: "exchange 0", chosenChoiceKind: nil
            )
        }
        let selectableIndexes = prompt.identity.questionPresentation?.choices.compactMap {
            $0.selectable ? $0.sourceIndex : nil
        } ?? []
        guard !selectableIndexes.isEmpty else {
            throw PlaythroughError.noSelectableChoice(
                version: prompt.questionVersion,
                tag: describeRawQuestionTag(prompt.identity.rawQuestion)
            )
        }
        let selectedIndex = preferredSelectableIndex(
            in: prompt,
            selectableIndexes: selectableIndexes,
            repeatCount: repeatCount,
            skillTestPreparationCount: skillTestPreparationCount
        )
        let chosenChoiceKind = prompt.identity.questionPresentation?.choices.first {
            $0.sourceIndex == selectedIndex
        }?.kind.rawValue
        return SelectedBotAnswer(
            answer: .choice(selectedIndex),
            note: "selectable choice \(selectedIndex)",
            chosenChoiceKind: chosenChoiceKind
        )
    }

    private func preferredSelectableIndex(
        in prompt: BasicChoicePromptPresentation,
        selectableIndexes: [Int],
        repeatCount: Int,
        skillTestPreparationCount: Int
    ) -> Int {
        if let skipIndex = prompt.identity.questionPresentation?.choices.first(where: {
            $0.selectable && $0.kind == .skipTriggers && selectableIndexes.contains($0.sourceIndex)
        })?.sourceIndex {
            return skipIndex
        }
        // Skill-test preparation offers legal commit/uncommit choices that can reorder the
        // same hand indefinitely. After a few legal prep actions, choose the server's
        // explicit start control; fail-closed behavior is preserved because the choice must
        // still be selectable in the current prompt.
        if skillTestPreparationCount >= 3 {
            let startSkillTestIndex = prompt.choices.first(where: {
                if case .startSkillTest = $0.content {
                    selectableIndexes.contains($0.index)
                } else {
                    false
                }
            })?.index
            if let startSkillTestIndex {
                return startSkillTestIndex
            }
        }
        return selectableIndexes[repeatCount % selectableIndexes.count]
    }

    private func canDiagnosticBypassUnsupported(_ prompt: BasicChoicePromptPresentation) -> Bool {
        guard diagnosticBypassUnsupported, prompt.readOnlyReason == nil else { return false }
        return prompt.identity.questionPresentation?.choices
            .contains { $0.selectable } == true
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func submit(
        _ answer: BotAnswer, prompt: BasicChoicePromptPresentation
    ) async throws -> SubmissionOutcome {
        let result: BasicChoiceSubmitResult
        switch answer {
        case let .choice(index):
            result = await model.submitBasicChoice(prompt.identity, choiceIndex: index)
        case let .amounts(amounts):
            result = await model.submitAmountsAnswer(prompt.identity, amounts: amounts)
        case let .paymentAmounts(amounts):
            result = await model.submitPaymentAmountsAnswer(prompt.identity, amounts: amounts)
        case let .exchangeAmount(amount):
            result = await model.submitExchangeAmountsAnswer(prompt.identity, amount: amount)
        case let .continueCampaign(step):
            result = await model.submitContinueCampaignAnswer(prompt.identity, step: step)
        case let .savedDeck(deck):
            guard await model.chooseDeckForLivePrompt(deck, in: gameID) else {
                throw PlaythroughError.submissionFailed("live deck choice was not accepted")
            }
            return SubmissionOutcome(
                detail: "submitted DeckAnswer through AppModel chooseDeckForLivePrompt"
            )
        case let .replacementDeck(originalInvestigatorID, deck):
            let deckResult = await model.upgradeCampaignDeck(
                using: deck,
                investigatorId: originalInvestigatorID,
                in: gameID,
                promptIdentity: prompt.identity
            )
            switch deckResult {
            case .submitted:
                let followUp = try await waitForReplacementFollowUp(
                    afterReplacing: originalInvestigatorID,
                    ownerID: prompt.identity.ownerID
                )
                return SubmissionOutcome(
                    detail: "submitted replacement deck through AppModel; "
                        + followUp.detail
                )
            case let .failed(message):
                throw PlaythroughError.submissionFailed(message)
            }
        case let .skipDeckUpgrade(investigatorID):
            let deckResult = await model.continueCampaignWithoutUpgrading(
                investigatorId: investigatorID,
                in: gameID,
                promptIdentity: prompt.identity
            )
            switch deckResult {
            case .submitted:
                return SubmissionOutcome(detail: "submitted deck-upgrade skip through AppModel")
            case let .failed(message):
                throw PlaythroughError.submissionFailed(message)
            }
        }
        switch result {
        case .sentAwaitingSnapshot:
            return SubmissionOutcome(detail: "sentAwaitingSnapshot")
        case .alreadyPending:
            throw PlaythroughError.submissionFailed("answer already pending")
        case .readOnly:
            throw PlaythroughError.submissionFailed("prompt became read-only")
        case .retryableFailure:
            throw PlaythroughError.submissionFailed("retryable answer failure")
        case .staleQuestion:
            throw PlaythroughError.submissionFailed("stale question")
        case .unsupportedChoice:
            guard diagnosticBypassUnsupported, case let .choice(index) = answer else {
                throw PlaythroughError.submissionFailed("unsupported choice")
            }
            return try await sendDiagnosticUnsupportedChoice(index, prompt: prompt)
        }
    }

    private func sendDiagnosticUnsupportedChoice(
        _ index: Int, prompt: BasicChoicePromptPresentation
    ) async throws -> SubmissionOutcome {
        guard let connection = model.liveGameConnections[gameID]?.connection else {
            throw PlaythroughError.submissionFailed("diagnostic bypass socket was not connected")
        }
        let bytes = try ContractJSON.encode(
            BasicChoiceAnswer(
                choice: index,
                playerID: prompt.identity.ownerID,
                questionVersion: prompt.identity.questionVersion
            )
        )
        try await connection.send(bytes)
        return SubmissionOutcome(
            detail: "diagnostic bypass sent unsupported Answer over WebSocket",
            diagnosticBypass: true
        )
    }

    private func waitForReplacementFollowUp(
        afterReplacing originalInvestigatorID: String,
        ownerID: PlayerID
    ) async throws -> ReplacementFollowUp {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let envelope = try await lifecycle.getGame(gameID, on: profile, token: token)
            let projection = BoardProjectionBuilder.makeProjection(from: envelope.game)
            guard let currentInvestigator = projection.investigators.first(where: {
                $0.playerID == ownerID
            }) else {
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            guard currentInvestigator.id.rawValue.rawValue != originalInvestigatorID else {
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            try await captureReplacementFollowUpIfRequested()
            return ReplacementFollowUp(investigatorID: currentInvestigator.id.rawValue.rawValue)
        }
        throw PlaythroughError.timedOut("replacement follow-up prompt")
    }

    private func waitForPromptAdvance(
        from identity: BasicChoicePromptIdentity,
        acceptingSeatInvestigatorChangeFrom previousSeatInvestigator: SeatInvestigatorIdentity?
            = nil
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(30)
        var nextServerStateCheck = Date()
        var ignoredServerSnapshotFailure = false
        while Date() < deadline {
            guard let current = model.basicChoicePresentation(for: gameID) else { return true }
            if current.identity.questionVersion != identity.questionVersion {
                return true
            }
            if modelSeatInvestigatorChanged(
                from: previousSeatInvestigator,
                currentOwnerID: current.identity.ownerID
            ) {
                return true
            }
            if Date() >= nextServerStateCheck {
                nextServerStateCheck = Date().addingTimeInterval(1)
                do {
                    if try await serverSnapshotShowsProgress(
                        from: identity,
                        acceptingSeatInvestigatorChangeFrom: previousSeatInvestigator
                    ) {
                        return true
                    }
                } catch {
                    guard !ignoredServerSnapshotFailure else { throw error }
                    ignoredServerSnapshotFailure = true
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func modelSeatInvestigatorChanged(
        from previousSeatInvestigator: SeatInvestigatorIdentity?,
        currentOwnerID: PlayerID
    ) -> Bool {
        guard let previousSeatInvestigator,
              currentOwnerID == previousSeatInvestigator.ownerID,
              let projection = model.liveGameState(for: gameID).lastKnownProjection,
              let currentSeatInvestigator = seatInvestigatorIdentity(
                  for: previousSeatInvestigator.ownerID,
                  in: projection
              )
        else { return false }
        return currentSeatInvestigator.investigatorID != previousSeatInvestigator.investigatorID
    }

    private func seatInvestigatorIdentity(
        for ownerID: PlayerID,
        in projection: BoardProjection
    ) -> SeatInvestigatorIdentity? {
        guard let investigator = projection.investigators.first(where: { $0.playerID == ownerID })
        else { return nil }
        return SeatInvestigatorIdentity(ownerID: ownerID, investigatorID: investigator.id)
    }

    private func captureReplacementPromptIfRequested(
        prompt: BasicChoicePromptPresentation,
        projection: BoardProjection
    ) async throws {
        guard prompt.isChooseUpgradeDeckPrompt,
              let directory = ProcessInfo.processInfo.environment[
                  "ARKHAM_LIVE_CAPTURE_REPLACEMENT_PROMPTS_DIR"
              ]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directory.isEmpty,
              let currentInvestigator = projection.investigators.first(where: {
                  $0.playerID == prompt.identity.ownerID
              })
        else { return }
        let context = CampaignUpgradeDeckContext.make(
            investigator: currentInvestigator,
            campaignSummary: projection.campaignSummary
        )
        let originalInvestigatorID = "c\(investigator.code)"
        let isReplacementFollowUp = currentInvestigator.id.rawValue.rawValue
            != originalInvestigatorID && context.allowsSkip
        let fileName: String
        if context.requiresReplacement {
            fileName = "campaign-replacement-choose-upgrade-deck.json"
        } else if isReplacementFollowUp {
            fileName = "campaign-replacement-follow-up-continue-campaign.json"
        } else {
            return
        }
        let url = URL(fileURLWithPath: directory).appending(path: fileName)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try await currentGameResponseData()
        try data.write(to: url, options: .atomic)
    }

    private func captureReplacementFollowUpIfRequested() async throws {
        guard let directory = ProcessInfo.processInfo.environment[
            "ARKHAM_LIVE_CAPTURE_REPLACEMENT_PROMPTS_DIR"
        ]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !directory.isEmpty
        else { return }
        let url = URL(fileURLWithPath: directory)
            .appending(path: "campaign-replacement-follow-up-continue-campaign.json")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try await currentGameResponseData()
        try data.write(to: url, options: .atomic)
    }

    private func currentGameResponseData() async throws -> Data {
        let path = "/arkham/games/\(gameID.rawValue.uuidString.lowercased())"
        let url = profile.endpointURL(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw PlaythroughError.submissionFailed(
                "replacement fixture capture GET returned HTTP \(status)"
            )
        }
        return data
    }

    private func serverSnapshotShowsProgress(
        from _: BasicChoicePromptIdentity,
        acceptingSeatInvestigatorChangeFrom previousSeatInvestigator: SeatInvestigatorIdentity?
    ) async throws -> Bool {
        let envelope = try await lifecycle.getGame(gameID, on: profile, token: token)
        if case .over = envelope.game.gameState {
            return true
        }
        let projection = BoardProjectionBuilder.makeProjection(from: envelope.game)
        guard let previousSeatInvestigator,
              let currentSeatInvestigator = seatInvestigatorIdentity(
                  for: previousSeatInvestigator.ownerID,
                  in: projection
              )
        else { return false }
        return currentSeatInvestigator.investigatorID != previousSeatInvestigator.investigatorID
    }

    private func minimumAmounts(for prompt: BasicChoiceAmountPrompt) -> [String: Int] {
        var amounts = Dictionary(uniqueKeysWithValues: prompt.rows.map { ($0.id, $0.minBound) })
        let minimumTotal = amounts.values.reduce(0, +)
        let target = targetAmount(prompt.target, minimumTotal: minimumTotal)
        var remaining = max(0, target - minimumTotal)
        for row in prompt.rows {
            guard remaining > 0 else { break }
            let extra = min(remaining, row.maxBound - row.minBound)
            amounts[row.id, default: row.minBound] += extra
            remaining -= extra
        }
        return amounts
    }

    private func targetAmount(
        _ target: QuestionPresentation.AmountTarget?,
        minimumTotal: Int
    ) -> Int {
        switch target {
        case nil:
            minimumTotal
        case let .min(minimum):
            max(minimum, minimumTotal)
        case .max:
            minimumTotal
        case let .total(total):
            total
        case let .oneOf(allowed):
            allowed.sorted().first { $0 >= minimumTotal } ?? minimumTotal
        }
    }

    private func isInitialChooseDeckPrompt(_ prompt: BasicChoicePromptPresentation) -> Bool {
        prompt.identity.rawQuestion == .object(["tag": .string("ChooseDeck")])
    }

    private func isContinueCampaignPrompt(_ prompt: BasicChoicePromptPresentation) -> Bool {
        if case .continueCampaign = prompt.semanticPresentation?.presentation.answer {
            return true
        }
        guard let object = prompt.identity.rawQuestion.objectValue else { return false }
        if object["tag"] == .string("ContinueCampaign") {
            return true
        }
        return object["tag"] == .string("QuestionLabel")
            && object["question"]?.objectValue?["tag"] == .string("ContinueCampaign")
    }
}

private enum BotAnswer: Sendable {
    case choice(Int)
    case amounts([String: Int])
    case paymentAmounts([String: Int])
    case exchangeAmount(Int)
    case continueCampaign(JSONValue)
    case savedDeck(Deck)
    case replacementDeck(originalInvestigatorID: String, deck: Deck)
    case skipDeckUpgrade(investigatorID: String)
}

private struct SelectedBotAnswer: Sendable {
    let answer: BotAnswer
    let note: String
    let chosenChoiceKind: String?
}

private struct SubmissionOutcome: Sendable {
    let detail: String
    let diagnosticBypass: Bool

    init(detail: String, diagnosticBypass: Bool = false) {
        self.detail = detail
        self.diagnosticBypass = diagnosticBypass
    }
}

private extension BotAnswer {
    // swiftlint:disable:next function_body_length
    func traceSubmission(prompt: BasicChoicePromptPresentation) throws -> TraceSubmission {
        switch self {
        case let .choice(index):
            return try TraceSubmission(
                kind: "Answer",
                payload: BasicChoiceAnswer(
                    choice: index,
                    playerID: prompt.identity.ownerID,
                    questionVersion: prompt.identity.questionVersion
                )
            )
        case let .amounts(amounts):
            return try TraceSubmission(
                kind: "AmountsAnswer",
                payload: AmountsAnswer(
                    amounts: amounts,
                    playerID: prompt.identity.ownerID,
                    questionVersion: prompt.identity.questionVersion
                )
            )
        case let .paymentAmounts(amounts):
            return try TraceSubmission(
                kind: "PaymentAmountsAnswer",
                payload: PaymentAmountsAnswer(
                    amounts: amounts,
                    playerID: prompt.identity.ownerID,
                    questionVersion: prompt.identity.questionVersion
                )
            )
        case let .exchangeAmount(amount):
            guard let presentation = prompt.identity.questionPresentation,
                  let source = presentation.source?.raw,
                  let fromInvestigator = presentation.fromInvestigator,
                  let toInvestigator = presentation.toInvestigator,
                  let token = presentation.token
            else { throw PlaythroughError.submissionFailed("invalid exchange presentation") }
            return try TraceSubmission(
                kind: "ExchangeAmountsAnswer",
                payload: ExchangeAmountsAnswer(
                    source: source,
                    fromInvestigator: fromInvestigator,
                    toInvestigator: toInvestigator,
                    token: token,
                    amount: amount
                )
            )
        case let .continueCampaign(step):
            return try TraceSubmission(
                kind: "CampaignStepAnswer",
                payload: CampaignStepAnswer(contents: step)
            )
        case let .savedDeck(deck):
            return try TraceSubmission(
                kind: "DeckAnswer",
                payload: DeckAnswer(deckId: deck.id, playerId: prompt.identity.ownerID)
            )
        case let .replacementDeck(originalInvestigatorID, deck):
            return TraceSubmission(
                kind: "ReplacementDeck",
                encodedPayload: .object([
                    "investigatorId": .string(originalInvestigatorID),
                    "deckUrl": deck.url.map(JSONValue.string) ?? .null,
                    "deckListInvestigatorCode": .string(
                        deck.playableList.investigatorCode.rawValue
                    ),
                ])
            )
        case let .skipDeckUpgrade(investigatorID):
            return TraceSubmission(
                kind: "SkipDeckUpgrade",
                encodedPayload: .object(["investigatorId": .string(investigatorID)])
            )
        }
    }
}

private struct BotOutcome {
    let reachedServerCompletion: Bool
    let scenarioOutcomes: [String: String]
    let promptFailure: PromptFailure?
}

private struct SeatInvestigatorIdentity: Sendable, Equatable {
    let ownerID: PlayerID
    let investigatorID: InvestigatorID
}

private struct ReplacementFollowUp: Sendable, Equatable {
    let investigatorID: String

    var detail: String {
        "server advanced after replacement to \(investigatorID)"
    }
}

private struct PromptFailure: Sendable, Equatable {
    let scenario: String
    let investigator: InvestigatorFixture
    let questionVersion: Int
    let rawQuestionTag: String
    let reason: String

    var description: String {
        "\(scenario) / \(investigator.name) / q\(questionVersion) / \(rawQuestionTag): \(reason)"
    }

    var markdownSummary: String {
        description.replacingOccurrences(of: "|", with: "\\|")
    }
}

private struct TraceSubmission: Encodable, Sendable {
    let kind: String
    let encodedPayload: JSONValue

    init(kind: String, encodedPayload: JSONValue) {
        self.kind = kind
        self.encodedPayload = encodedPayload
    }

    init(kind: String, payload: some Encodable) throws {
        let data = try ContractJSON.encode(payload)
        self.kind = kind
        encodedPayload = try ContractJSON.decode(JSONValue.self, from: data)
    }
}

private struct TraceServerFeedback: Encodable, Sendable {
    let source: String
    let message: String

    var description: String {
        "serverFeedback=\(source): \(message)"
    }
}

private struct TraceOutcome: Encodable, Sendable {
    let kind: String
    let detail: String

    static func submittedAndAdvanced(_ detail: String) -> Self {
        TraceOutcome(kind: "submittedAndAdvanced", detail: detail)
    }

    static func failed(_ detail: String) -> Self {
        TraceOutcome(kind: "failed", detail: detail)
    }
}

private struct TraceSelectedAnswer: Encodable, Sendable {
    let note: String
    let chosenChoiceKind: String?
    let answerKind: String
    let choiceIndex: Int?
}

private struct TraceAppChoice: Encodable, Sendable {
    let index: Int
    /// The title rendered by `BasicChoicePromptView` through
    /// `BasicChoicePromptPresentation.resolvedChoiceLabel`, not the legacy raw parser title.
    let title: String
    let legacyRawTitle: String
    let contentKind: String
    let isSupported: Bool
    let isDisplayed: Bool
    let isActionable: Bool
    let isSubmittable: Bool
    let blocksSubmission: Bool
    let semanticKind: String?
    let semanticSelectable: Bool?
    let systemImage: String
    let accessibilityLabel: String
    let accessibilityHint: String
    let rendersUpdateRequired: Bool
    let rawValue: JSONValue
}

private struct TracePromptState: Encodable, Sendable {
    let ownerID: PlayerID
    let questionVersion: Int
    let rawQuestionTag: String
    let questionKind: String?
    let rawQuestion: JSONValue
    let questionPresentation: QuestionPresentation?
    let serverSelectableIndexes: [Int]
    let appDisplayOrderedChoiceIndexes: [Int]
    let appChoices: [TraceAppChoice]
    let isRenderableQuestion: Bool
    let canSubmit: Bool
    let statusMessage: String?
    let readOnlyReason: String?
    let actionPhase: String?
}

private struct PlaythroughTraceRecord: Encodable, Sendable {
    let event: String
    let timestamp: String
    let investigatorCode: String
    let investigatorName: String
    let gameID: String
    let scenario: String?
    let repeatCount: Int?
    let prompt: TracePromptState?
    let selectedAnswer: TraceSelectedAnswer?
    let submission: TraceSubmission?
    let outcome: TraceOutcome?
    let serverFeedback: TraceServerFeedback?
    let diagnosticBypass: Bool
    let scenarioOutcomes: [String: String]?

    static func runStarted(
        investigator: InvestigatorFixture, gameID: GameID
    ) -> PlaythroughTraceRecord {
        base(
            event: "runStarted",
            investigator: investigator,
            gameID: gameID,
            scenarioOutcomes: nil
        )
    }

    static func runFinished(
        investigator: InvestigatorFixture,
        gameID: GameID,
        reachedServerCompletion: Bool,
        scenarioOutcomes: [String: String]
    ) -> PlaythroughTraceRecord {
        base(
            event: "runFinished",
            investigator: investigator,
            gameID: gameID,
            outcome: TraceOutcome(
                kind: reachedServerCompletion ? "passed" : "failed",
                detail: "gameState IsOver"
            ),
            scenarioOutcomes: scenarioOutcomes
        )
    }

    static func runTimedOut(
        investigator: InvestigatorFixture,
        gameID: GameID,
        failure: PromptFailure,
        scenarioOutcomes: [String: String]
    ) -> PlaythroughTraceRecord {
        base(
            event: "runTimedOut",
            investigator: investigator,
            gameID: gameID,
            scenario: failure.scenario,
            outcome: .failed(failure.reason),
            scenarioOutcomes: scenarioOutcomes
        )
    }

    // swiftlint:disable:next function_parameter_count
    static func prompt(
        investigator: InvestigatorFixture,
        gameID: GameID,
        scenario: String,
        prompt: BasicChoicePromptPresentation,
        projection: BoardProjection,
        repeatCount: Int,
        selectedAnswer: SelectedBotAnswer?,
        submission: TraceSubmission?,
        outcome: TraceOutcome,
        serverFeedback: TraceServerFeedback?,
        diagnosticBypass: Bool = false
    ) -> PlaythroughTraceRecord {
        base(
            event: "prompt",
            investigator: investigator,
            gameID: gameID,
            scenario: scenario,
            repeatCount: repeatCount,
            prompt: TracePromptState(prompt: prompt, projection: projection),
            selectedAnswer: selectedAnswer.map(TraceSelectedAnswer.init),
            submission: submission,
            outcome: outcome,
            serverFeedback: serverFeedback,
            diagnosticBypass: diagnosticBypass,
            scenarioOutcomes: nil
        )
    }

    private static func base(
        event: String,
        investigator: InvestigatorFixture,
        gameID: GameID,
        scenario: String? = nil,
        repeatCount: Int? = nil,
        prompt: TracePromptState? = nil,
        selectedAnswer: TraceSelectedAnswer? = nil,
        submission: TraceSubmission? = nil,
        outcome: TraceOutcome? = nil,
        serverFeedback: TraceServerFeedback? = nil,
        diagnosticBypass: Bool = false,
        scenarioOutcomes: [String: String]?
    ) -> PlaythroughTraceRecord {
        PlaythroughTraceRecord(
            event: event,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            investigatorCode: investigator.code,
            investigatorName: investigator.name,
            gameID: gameID.rawValue.uuidString.lowercased(),
            scenario: scenario,
            repeatCount: repeatCount,
            prompt: prompt,
            selectedAnswer: selectedAnswer,
            submission: submission,
            outcome: outcome,
            serverFeedback: serverFeedback,
            diagnosticBypass: diagnosticBypass,
            scenarioOutcomes: scenarioOutcomes
        )
    }
}

private extension TraceSelectedAnswer {
    init(_ answer: SelectedBotAnswer) {
        note = answer.note
        chosenChoiceKind = answer.chosenChoiceKind
        switch answer.answer {
        case let .choice(index):
            answerKind = "Answer"
            choiceIndex = index
        case .amounts:
            answerKind = "AmountsAnswer"
            choiceIndex = nil
        case .paymentAmounts:
            answerKind = "PaymentAmountsAnswer"
            choiceIndex = nil
        case .exchangeAmount:
            answerKind = "ExchangeAmountsAnswer"
            choiceIndex = nil
        case .continueCampaign:
            answerKind = "CampaignStepAnswer"
            choiceIndex = nil
        case .savedDeck:
            answerKind = "DeckAnswer"
            choiceIndex = nil
        case .replacementDeck:
            answerKind = "ReplacementDeck"
            choiceIndex = nil
        case .skipDeckUpgrade:
            answerKind = "SkipDeckUpgrade"
            choiceIndex = nil
        }
    }
}

private extension TracePromptState {
    init(prompt: BasicChoicePromptPresentation, projection: BoardProjection) {
        let serverChoices = prompt.identity.questionPresentation?.choices ?? []
        let displayChoices = prompt.displayOrderedChoices()
        ownerID = prompt.identity.ownerID
        questionVersion = prompt.questionVersion
        rawQuestionTag = describeRawQuestionTag(prompt.identity.rawQuestion)
        questionKind = prompt.identity.questionPresentation?.questionKind.rawValue
        rawQuestion = prompt.identity.rawQuestion
        questionPresentation = prompt.identity.questionPresentation
        serverSelectableIndexes = serverChoices.compactMap { $0.selectable ? $0.sourceIndex : nil }
        appDisplayOrderedChoiceIndexes = displayChoices.map(\.index)
        appChoices = traceAppChoices(prompt: prompt, projection: projection)
        isRenderableQuestion = prompt.isRenderableQuestion
        canSubmit = prompt.canSubmit
        statusMessage = prompt.statusMessage
        readOnlyReason = prompt.readOnlyReason.map(describeReadOnlyReason)
        actionPhase = prompt.actionPhase.map(describeActionPhase)
    }
}

private struct PlaythroughTraceRecorder: Sendable {
    let path: String

    func reset() throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data().write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func append(_ record: PlaythroughTraceRecord) throws {
        var data = try ContractJSON.encode(record)
        data.append(0x0A)
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url, options: .atomic)
        }
    }
}

private struct PlaythroughResult: Sendable {
    let investigator: InvestigatorFixture
    let status: PlaythroughStatus
    let scenarioOutcomes: [String: String]
    let promptFailure: PromptFailure?
    let finalGameID: String?
}

private enum PlaythroughStatus: Sendable, Equatable {
    case passed
    case failed(String)

    var isPassed: Bool {
        if case .passed = self {
            true
        } else {
            false
        }
    }

    var tableText: String {
        switch self {
        case .passed: "passed"
        case let .failed(reason): "failed — \(reason.replacingOccurrences(of: "|", with: "\\|"))"
        }
    }
}

private enum PlaythroughError: Error, CustomStringConvertible {
    case notSignedOut(String)
    case notSignedIn(String)
    case registrationDidNotStart
    case noSelectableChoice(version: Int, tag: String)
    case cardCatalogUnavailable(String)
    case submissionFailed(String)
    case noEligibleReplacementInvestigator(String)
    case noPromptOwnerInvestigator(PlayerID)
    case timedOut(String)

    var description: String {
        switch self {
        case let .notSignedOut(state): "expected signedOut after launch, got \(state)"
        case let .notSignedIn(state): "expected signedIn, got \(state)"
        case .registrationDidNotStart: "registration did not start"
        case let .noSelectableChoice(version, tag): "no selectable choice at q\(version) / \(tag)"
        case let .cardCatalogUnavailable(reason): "card catalog unavailable: \(reason)"
        case let .submissionFailed(reason): "submission failed: \(reason)"
        case let .noEligibleReplacementInvestigator(investigatorID):
            "no eligible core replacement investigator for \(investigatorID)"
        case let .noPromptOwnerInvestigator(playerID):
            "no current investigator for prompt owner \(playerID.rawValue.uuidString)"
        case let .timedOut(description): "timed out waiting for \(description)"
        }
    }
}

private struct InvestigatorFixture: Sendable, Equatable {
    let code: String
    let name: String
    let weakness: String
    let requiredCards: [String]
    let ordinaryCards: [String]
    let secondCopies: [String]

    static let core: [InvestigatorFixture] = [
        InvestigatorFixture(
            code: "01001", name: "Roland Banks", weakness: "01097",
            requiredCards: ["01006", "01007"],
            ordinaryCards: guardian0 + seeker0 + neutralCore,
            secondCopies: ["01017", "01020"]
        ),
        InvestigatorFixture(
            code: "01002", name: "Daisy Walker", weakness: "01098",
            requiredCards: ["01008", "01009"],
            ordinaryCards: seeker0 + mystic0 + neutralCore,
            secondCopies: ["01031", "01033"]
        ),
        InvestigatorFixture(
            code: "01003", name: "Skids O'Toole", weakness: "01099",
            requiredCards: ["01010", "01011"],
            ordinaryCards: rogue0 + guardian0 + neutralCore,
            secondCopies: ["01047", "01048"]
        ),
        InvestigatorFixture(
            code: "01004", name: "Agnes Baker", weakness: "01100",
            requiredCards: ["01012", "01013"],
            ordinaryCards: mystic0 + survivor0 + neutralCore,
            secondCopies: ["01059", "01060"]
        ),
        InvestigatorFixture(
            code: "01005", name: "Wendy Adams", weakness: "01101",
            requiredCards: ["01014", "01015"],
            ordinaryCards: survivor0 + rogue0 + neutralCore,
            secondCopies: ["01048", "01049"]
        ),
    ]

    var deckSlots: [String: Int] {
        var slots: [String: Int] = [:]
        for card in requiredCards + ordinaryCards {
            slots[card, default: 0] += 1
        }
        for card in secondCopies {
            slots[card, default: 0] += 1
        }
        slots[weakness, default: 0] += 1
        return slots
    }

    var traceSlug: String {
        name.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: " ", with: "-")
    }

    var createDeckRequest: CreateDeckRequest {
        guard let investigatorCode = try? InvestigatorCode(code) else {
            fatalError("Core investigator code fixture must be non-empty")
        }
        return CreateDeckRequest(
            deckId: "task-1.20.1-\(code)-\(UUID().uuidString.lowercased())",
            deckName: "\(name) task-1.20.1 starter",
            deckUrl: nil,
            deckList: DeckListInput(
                slots: CardQuantityMapInput(deckSlots),
                sideSlots: .valid(CardQuantityMapInput([:])),
                investigatorCode: investigatorCode,
                investigatorName: name,
                meta: nil,
                tabooId: nil,
                url: nil,
                id: .string("task-1.20.1-\(code)"),
                name: "\(name) task-1.20.1 starter"
            )
        )
    }

    private static let neutralCore = [
        "01086", "01087", "01088", "01089", "01090", "01091", "01092", "01093",
    ]
    private static let guardian0 = [
        "01016", "01017", "01018", "01019", "01020", "01021", "01022", "01023",
        "01024", "01025",
    ]
    private static let seeker0 = [
        "01030", "01031", "01032", "01033", "01034", "01035", "01036", "01037",
        "01038", "01039",
    ]
    private static let rogue0 = [
        "01044", "01045", "01046", "01047", "01048", "01049", "01050", "01051",
        "01052", "01053",
    ]
    private static let mystic0 = [
        "01058", "01059", "01060", "01061", "01062", "01063", "01064", "01065",
        "01066", "01067",
    ]
    private static let survivor0 = [
        "01072", "01073", "01074", "01075", "01076", "01077", "01078", "01079",
        "01080", "01081",
    ]
}

private extension BasicChoicePromptIdentity {
    var diagnosticKey: String {
        "\(gameID.rawValue.uuidString):\(ownerID.rawValue.uuidString):\(questionVersion):"
            + jsonString(rawQuestion)
    }
}

private enum LiveHarnessFixtureError: Error, Equatable {
    case missingContractFixture(String)
    case expectedCampaignAndScenario
    case expectedScenario
}

private func liveHarnessGameModeFixture(named name: String) throws -> GameMode {
    guard let url = Bundle.module.url(
        forResource: name,
        withExtension: "json",
        subdirectory: "Fixtures/Contract"
    ) else { throw LiveHarnessFixtureError.missingContractFixture(name) }
    return try ContractJSON.decode(GameMode.self, from: Data(contentsOf: url))
}

private func liveHarnessScenarioOnlyMode() throws -> GameMode {
    let mode = try liveHarnessGameModeFixture(named: "mode-campaign-scenario")
    guard case let .campaignAndScenario(_, scenario) = mode else {
        throw LiveHarnessFixtureError.expectedCampaignAndScenario
    }
    return .scenarioOnly(scenario)
}

private func scenarioID(in mode: GameMode) throws -> String {
    switch mode {
    case let .scenarioOnly(scenario), let .campaignAndScenario(_, scenario):
        scenario.id.rawValue
    case .campaignOnly:
        throw LiveHarnessFixtureError.expectedScenario
    }
}

private func currentScenarioCode(
    projection: BoardProjection?,
    snapshot: PublicGameSnapshot
) -> String {
    if let reference = projection?.scenario?.reference {
        return reference
    }
    switch snapshot.mode {
    case let .scenarioOnly(scenario), let .campaignAndScenario(_, scenario):
        return scenario.id.rawValue
    case let .campaignOnly(campaign):
        return campaignStepScenarioID(campaign.objectValue?["step"])
            ?? campaign.objectValue?["id"]?.stringValue
            ?? "campaign"
    }
}

private func scenarioOutcomes(from snapshot: PublicGameSnapshot) -> [String: String] {
    scenarioOutcomes(from: snapshot.mode)
}

private func scenarioOutcomes(from mode: GameMode) -> [String: String] {
    switch mode {
    case let .campaignOnly(campaign), let .campaignAndScenario(campaign, _):
        campaignScenarioOutcomes(from: campaign)
    case .scenarioOnly:
        [:]
    }
}

private func terminalScenarioOutcomes(from snapshot: PublicGameSnapshot) -> [String: String] {
    terminalScenarioOutcomes(from: snapshot.mode)
}

private func terminalScenarioOutcomes(from mode: GameMode) -> [String: String] {
    var outcomes = scenarioOutcomes(from: mode)
    guard outcomes.isEmpty else { return outcomes }
    switch mode {
    case .campaignOnly:
        outcomes["campaign"] = "gameState IsOver"
    case let .campaignAndScenario(_, scenario), let .scenarioOnly(scenario):
        outcomes[scenario.id.rawValue] = "gameState IsOver"
    }
    return outcomes
}

private func campaignScenarioOutcomes(from campaign: JSONValue) -> [String: String] {
    guard let object = campaign.objectValue else { return [:] }
    let resolutions = object["resolutions"]?.objectValue ?? [:]
    var outcomes: [String: String] = [:]
    var consumedResolutionKeys = Set<String>()
    for scenarioID in campaignStepScenarioIDs(in: object["completedSteps"]) {
        if let entry = resolutionEntry(for: scenarioID, in: resolutions) {
            outcomes[scenarioID] = "resolution \(jsonString(entry.value))"
            consumedResolutionKeys.insert(entry.key)
        } else {
            outcomes[scenarioID] = "completed without recorded resolution"
        }
    }
    for key in resolutions.keys.sorted() where !consumedResolutionKeys.contains(key) {
        if let value = resolutions[key] {
            outcomes[key] = "resolution \(jsonString(value))"
        }
    }
    return outcomes
}

private func campaignStepScenarioIDs(in completedSteps: JSONValue?) -> [String] {
    guard let steps = completedSteps?.arrayValue else { return [] }
    // The server prepends completed campaign steps; reverse to report oldest -> newest.
    return steps.reversed().compactMap(campaignStepScenarioID)
}

private func campaignStepScenarioID(_ step: JSONValue?) -> String? {
    guard let object = step?.objectValue,
          let tag = object["tag"]?.stringValue,
          [
              "ScenarioStep",
              "ScenarioStepWithOptions",
              "StandaloneScenarioStep",
              "StandaloneScenarioStepWithOptions",
          ].contains(tag)
    else { return nil }
    if let contents = object["contents"]?.stringValue {
        return contents
    }
    if let contents = object["contents"]?.arrayValue?.first?.stringValue {
        return contents
    }
    return nil
}

private func resolutionEntry(
    for scenarioID: String,
    in resolutions: [String: JSONValue]
) -> (key: String, value: JSONValue)? {
    let candidates = scenarioID.hasPrefix("c")
        ? [scenarioID, String(scenarioID.dropFirst())]
        : [scenarioID, "c\(scenarioID)"]
    for candidate in candidates {
        if let value = resolutions[candidate] {
            return (key: candidate, value: value)
        }
    }
    return nil
}

private func describeRawQuestionTag(_ value: JSONValue) -> String {
    guard let object = value.objectValue else { return value.kindDescription }
    if let tag = object["tag"]?.stringValue {
        return tag
    }
    return value.kindDescription
}

private func coverageRepeatKey(
    scenario: String, prompt: BasicChoicePromptPresentation
) -> String {
    let presentation = prompt.identity.questionPresentation
        .flatMap { try? encodedJSONValue($0) }
        .map(presentationWithoutQuestionVersion) ?? .null
    return [
        scenario,
        jsonString(prompt.identity.rawQuestion),
        jsonString(presentation),
    ].joined(separator: ":")
}

private func skillTestPreparationLoopKey(
    scenario: String, prompt: BasicChoicePromptPresentation
) -> String? {
    guard prompt.choices.contains(where: {
        if case .startSkillTest = $0.content {
            true
        } else {
            false
        }
    }) else { return nil }
    return [
        scenario,
        prompt.identity.ownerID.rawValue.uuidString.lowercased(),
        "startSkillTestPreparation",
    ].joined(separator: ":")
}

private func presentationWithoutQuestionVersion(_ value: JSONValue) -> JSONValue {
    guard case var .object(object) = value else { return value }
    object.removeValue(forKey: "questionVersion")
    return .object(object)
}

private func encodedJSONValue(_ value: some Encodable) throws -> JSONValue {
    let data = try ContractJSON.encode(value)
    return try ContractJSON.decode(JSONValue.self, from: data)
}

private func traceAppChoices(
    prompt: BasicChoicePromptPresentation, projection: BoardProjection
) -> [TraceAppChoice] {
    let displayed = Set(prompt.displayOrderedChoices().map(\.index))
    return prompt.choices.map { choice in
        let descriptor = prompt.identity.questionPresentation?.choices.first {
            $0.sourceIndex == choice.index
        }
        let resolved = prompt.resolvedChoiceLabel(for: choice, in: projection)
        let accessibilityHint = prompt.accessibilityHint(for: choice, in: projection)
        let isDisplayed = displayed.contains(choice.index)
        let isActionable = prompt.isChoiceActionable(choice, in: projection)
        let isSubmittable = prompt.canSubmit && isActionable
        return TraceAppChoice(
            index: choice.index,
            title: resolved.title,
            legacyRawTitle: choice.title,
            contentKind: choiceContentKind(choice.content),
            isSupported: choice.isSupported,
            isDisplayed: isDisplayed,
            isActionable: isActionable,
            isSubmittable: isSubmittable,
            blocksSubmission: isDisplayed && !isSubmittable,
            semanticKind: descriptor?.kind.rawValue,
            semanticSelectable: descriptor?.selectable,
            systemImage: resolved.systemImage,
            accessibilityLabel: resolved.accessibilityLabel,
            accessibilityHint: accessibilityHint,
            rendersUpdateRequired: !prompt.isRenderableQuestion
                || resolved.title == "Update required",
            rawValue: choice.rawValue
        )
    }
}

// swiftlint:disable:next cyclomatic_complexity
private func choiceContentKind(_ content: BasicChoiceContent) -> String {
    switch content {
    case .gainResource: "gainResource"
    case .drawCard: "drawCard"
    case .drawEncounterCard: "drawEncounterCard"
    case .resolveEnemyAttack: "resolveEnemyAttack"
    case .assignEnemyAttackDamage: "assignEnemyAttackDamage"
    case .endTurn: "endTurn"
    case .investigate: "investigate"
    case .fight: "fight"
    case .evade: "evade"
    case .engage: "engage"
    case .rolandDefeatReaction: "rolandDefeatReaction"
    case .coverUpReaction: "coverUpReaction"
    case .resolveForcedAbility: "resolveForcedAbility"
    case .advanceAgenda: "advanceAgenda"
    case .chooseAgendaConsequence: "chooseAgendaConsequence"
    case .assignAgendaHorror: "assignAgendaHorror"
    case .continueReading: "continueReading"
    case .finishMulligan: "finishMulligan"
    case .chooseLocation: "chooseLocation"
    case .chooseHandCard: "chooseHandCard"
    case .skipTriggers: "skipTriggers"
    case .startSkillTest: "startSkillTest"
    case .applySkillTestResults: "applySkillTestResults"
    case .unsupported: "unsupported"
    }
}

private func describeReadOnlyReason(_ reason: BasicChoiceReadOnlyReason) -> String {
    switch reason {
    case .spectator: "spectator"
    case .anotherPlayer: "anotherPlayer"
    case .legacyServer: "legacyServer"
    case .updateRequired: "updateRequired"
    case .disconnected: "disconnected"
    }
}

private func describeActionPhase(_ phase: BasicChoiceActionPhase) -> String {
    switch phase {
    case .sending: "sending"
    case .awaitingSnapshot: "awaitingSnapshot"
    case .uncertain: "uncertain"
    case .retryable(.transportFailure): "retryable.transportFailure"
    case .retryable(.serverRejected): "retryable.serverRejected"
    case .retryable(.outcomeUncertain): "retryable.outcomeUncertain"
    }
}

private func jsonString(_ value: JSONValue) -> String {
    guard let data = try? ContractJSON.encode(value),
          let string = String(data: data, encoding: .utf8)
    else { return value.kindDescription }
    return string
}

private extension String {
    func withMarkdownTablePipes() -> String {
        "| \(self) |"
    }
}

@MainActor
private func waitUntil(
    timeout: TimeInterval,
    description: String,
    predicate: @escaping @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() {
            return
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw PlaythroughError.timedOut(description)
}

@MainActor
private func waitForValue<T>(
    timeout: TimeInterval,
    description: String,
    producer: @escaping @MainActor () -> T?
) async throws -> T {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let value = producer() {
            return value
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw PlaythroughError.timedOut(description)
}
