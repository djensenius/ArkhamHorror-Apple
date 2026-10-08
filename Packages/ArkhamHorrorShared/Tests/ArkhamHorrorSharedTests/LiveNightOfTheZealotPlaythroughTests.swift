// swiftlint:disable file_length
@testable import ArkhamHorrorShared
import Foundation
import Testing

func liveHarnessSelectableChoiceIndexes(
    prompt: BasicChoicePromptPresentation,
    projection: BoardProjection
) -> [Int] {
    prompt.displayOrderedChoices().compactMap { choice in
        prompt.isChoiceActionable(choice, in: projection) ? choice.index : nil
    }
}

private func liveHarnessDiagnosticBypassSelectableChoiceIndexes(
    prompt: BasicChoicePromptPresentation
) -> [Int] {
    prompt.identity.questionPresentation?.choices.compactMap { choice in
        choice.selectable ? choice.sourceIndex : nil
    } ?? []
}

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
    let botSeed: UInt64

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
        let botSeed = try parseBotSeed(trimmedValue("ARKHAM_LIVE_BOT_SEED", in: environment))
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
            shouldWriteLegacyNightOfTheZealotSummary: shouldWriteLegacy,
            botSeed: botSeed
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
    case invalidBotSeed(String)

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
        case let .invalidBotSeed(value):
            "ARKHAM_LIVE_BOT_SEED must be an unsigned integer, got '\(value)'"
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

private func parseBotSeed(_ value: String?) throws -> UInt64 {
    guard let value else { return 0 }
    guard let seed = UInt64(value) else {
        throw LiveHarnessConfigurationError.invalidBotSeed(value)
    }
    return seed
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

private func preferredScarletKeysTravelAction(
    _ prompt: ScarletKeysTravelPromptPresentation
) -> ScarletKeysTravelPromptPresentation.Action? {
    prompt.actions
        .filter(\.isActionable)
        .min { lhs, rhs in
            let lhsPriority = scarletKeysTravelActionPriority(lhs.kind)
            let rhsPriority = scarletKeysTravelActionPriority(rhs.kind)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.id < rhs.id
        }
}

private func scarletKeysTravelActionPriority(
    _ kind: ScarletKeysTravelPromptPresentation.Action.Kind
) -> Int {
    switch kind {
    case .travel:
        0
    case .travelWithTicket:
        1
    case .travelVia:
        2
    }
}

private func pickDestinyBotSelection(
    _ drawings: [QuestionPresentation.DestinyDrawing]
) -> [QuestionPresentation.DestinyDrawing] {
    let requiredReversed = PickDestinySelectionRules.requiredReversedCount(
        for: drawings.count
    )
    var reversedCount = 0
    return drawings.map { drawing in
        let targetFacing: QuestionPresentation.TarotCard.Facing = reversedCount < requiredReversed
            ? .reversed
            : .upright
        if targetFacing == .reversed {
            reversedCount += 1
        }
        guard drawing.tarot.facing != targetFacing else { return drawing }
        return QuestionPresentation.DestinyDrawing(
            scenario: drawing.scenario,
            tarot: QuestionPresentation.TarotCard(
                facing: targetFacing,
                arcana: drawing.tarot.arcana
            )
        )
    }
}

private func eligibleCoreReplacementDeck(
    originalInvestigatorCode: String,
    killedOrInsaneInvestigatorIDs: Set<String>,
    takenInvestigatorIDs: Set<String>,
    replacementDecksByCode: [String: Deck]
) -> Deck? {
    let originalInvestigatorID = "c\(originalInvestigatorCode)"
    for fixture in InvestigatorFixture.replacementPool {
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

private struct CapturedLivePromptFixture: Decodable {
    let questionVersion: Int
    let rawQuestion: JSONValue
    let questionPresentation: QuestionPresentation
}

private struct LiveHarnessPreferredLanguages: PreferredLanguagesProviding {
    let preferredLanguages: [String]
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

    @Test("Live harness uses non-core support replacements after the core pool")
    func deckUpgradeUsesSupportReplacementWhenCorePoolIsExhausted() throws {
        let ownerID = PlayerID(UUID())
        let currentInvestigatorID = try InvestigatorID(CardCode("c01005"))
        let unavailable = InvestigatorFixture.core.map { "c\($0.code)" }
        let projection = try Self.campaignDeckUpgradeProjection(
            ownerID: ownerID,
            currentInvestigatorID: currentInvestigatorID,
            killedOrInsaneInvestigatorIDs: unavailable
        )
        let decks = try Dictionary(uniqueKeysWithValues: InvestigatorFixture.replacementPool.map {
            try ($0.code, Self.deckFixture(for: $0))
        })

        let selected = try campaignDeckUpgradeBotSelection(
            promptOwnerID: ownerID,
            projection: projection,
            replacementDecksByCode: decks
        )

        guard case let .replacementDeck(originalInvestigatorID, deck) = selected.answer else {
            Issue.record("Expected a non-core replacement deck selection")
            return
        }
        #expect(originalInvestigatorID == "c01005")
        #expect(deck.playableList.investigatorCode.rawValue == "c02001")
    }

    @Test("Live bot chooses Forgotten Age supplies before Done")
    func botStrategyChoosesForgottenAgeSuppliesBeforeDone() throws {
        let initialPrompt = try Self.capturedForgottenAgeSupplyPrompt(
            named: "forgotten-age-pick-supplies-initial-q5"
        )
        let resupplyPrompt = try Self.capturedForgottenAgeSupplyPrompt(
            named: "forgotten-age-pick-supplies-resupply-q122"
        )

        #expect(Self.selectedBotIndex(in: initialPrompt) == 1)
        #expect(Self.selectedBotIndex(in: resupplyPrompt) == 1)
    }

    @Test("Return Circle Undone destiny prompt is answerable")
    func returnCircleUndonePickDestinyPromptIsAnswerable() throws {
        let fixture = try Self.capturedCircleUndonePrompt(
            named: "return-circle-undone-pick-destiny-q4"
        )
        let prompt = try Self.promptFromFixture(fixture, model: AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        ))
        let drawings = try #require(prompt.pickDestinyDrawings)
        let selected = pickDestinyBotSelection(drawings)
        let payload = try ContractJSON.encode(PickDestinyAnswer(contents: selected))
        let decoded = try ContractJSON.decode(PickDestinyAnswer.self, from: payload)

        #expect(prompt.isRenderableQuestion)
        #expect(prompt.canSubmit)
        #expect(drawings.map(\.scenario) == selected.map(\.scenario))
        #expect(drawings.map(\.tarot.arcana) == selected.map(\.tarot.arcana))
        #expect(selected.filter { $0.tarot.facing == .reversed }.count == 4)
        #expect(decoded.contents == selected)
    }

    @Test("Pick Destiny bot selection flips cards back to the exact reversed target")
    func pickDestinyBotSelectionSetsExactReversedCount() {
        let drawings = [
            Self.destinyDrawing(scenario: "one", arcana: "TemperanceXIV", facing: .reversed),
            Self.destinyDrawing(scenario: "two", arcana: "JusticeXI", facing: .reversed),
            Self.destinyDrawing(scenario: "three", arcana: "TheHermitIX", facing: .reversed),
            Self.destinyDrawing(scenario: "four", arcana: "TheHangedManXII", facing: .upright),
        ]

        let selected = pickDestinyBotSelection(drawings)

        #expect(selected.filter { $0.tarot.facing == .reversed }.count == 2)
        #expect(selected.map(\.scenario) == drawings.map(\.scenario))
        #expect(selected.map(\.tarot.arcana) == drawings.map(\.tarot.arcana))
    }

    @Test("Return Forgotten Age supply-point amount prompt resolves its row label")
    func returnForgottenAgeSupplyPointAmountPromptIsAnswerable() async throws {
        let title = "Catalog supply points"
        let model = try await Self.appModelWithCatalog(entries: [
            "choice.supplyPoints": title,
        ])
        let fixture = try Self.capturedForgottenAgePrompt(
            named: "return-forgotten-age-supply-points-choose-amounts-q147"
        )
        let prompt = try Self.promptFromFixture(fixture, model: model)
        let amountPrompt = try #require(prompt.amountPrompt(in: Self.strategyProjection()))
        let amountChoice = try #require(fixture.questionPresentation.amountChoices?.first)

        #expect(prompt.promptLabelResolutions[
            "amountChoice.\(amountChoice.choiceID)"
        ] == .resolved(title))
        #expect(prompt.canSubmit)
        #expect(amountPrompt.visibleRows.map(\.title) == [title])
    }

    @Test("ChooseAmounts row labels use the web choice namespace only")
    func amountRowLabelsUseWebChoiceNamespaceOnly() async throws {
        let model = try await Self.appModelWithCatalog(entries: [
            "x": "Plain x",
            "choice.x": "Choice x",
            "choice.foo.bar": "Choice dotted",
            "choice.supplyPoints": "Choice supply points",
        ])

        try Self.assertPlainLabelDoesNotUseChoiceNamespace(model: model)
        let amountResolutions = model.promptLabelResolutions(
            for: Self.amountNamespacePresentation()
        )
        #expect(amountResolutions["label"] == .resolved("Plain x"))
        #expect(amountResolutions["amountChoice.x-row"] == .resolved("Choice x"))
        #expect(amountResolutions["amountChoice.dotted-row"] == .resolved("Choice dotted"))
        #expect(amountResolutions["amountChoice.missing-row"] == .unavailable(.missingKey))
    }

    @Test("Live harness treats same-version prompt-key changes as progress")
    func promptAdvanceUsesFullPromptKeyAtSameVersion() {
        let rawQuestion: JSONValue = .object(["tag": .string("ChooseOne")])
        let original = Self.prompt(
            questionVersion: 7,
            rawQuestion: rawQuestion,
            questionPresentation: Self.semanticPresentation(choiceKind: .gainResource)
        )
        let samePrompt = Self.prompt(
            questionVersion: 7,
            rawQuestion: rawQuestion,
            questionPresentation: Self.semanticPresentation(choiceKind: .gainResource)
        )
        let changedPrompt = Self.prompt(
            questionVersion: 7,
            rawQuestion: rawQuestion,
            questionPresentation: Self.semanticPresentation(choiceKind: .drawCard)
        )

        #expect(!basicChoicePromptAdvanced(from: original.identity, to: samePrompt))
        #expect(basicChoicePromptAdvanced(from: original.identity, to: changedPrompt))
    }

    @Test("Live harness resets skill-test preparation bounds between tests")
    func skillTestPreparationCounterResetsBetweenSeparateSkillTests() throws {
        let prompt = try Self.skillTestPreparationPrompt(questionVersion: 11)
        let selectableIndexes = [0, 1]
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let loopKey = "c01104:00000000-0000-0000-0000-000000000800:startSkillTestPreparation"
        var counter = SkillTestPreparationLoopCounter()

        #expect(counter.count(for: loopKey) == 0)
        #expect(preferredSelectableIndex(
            in: prompt,
            projection: projection,
            selectableIndexes: selectableIndexes,
            repeatCount: 0,
            skillTestPreparationCount: counter.count(for: loopKey)
        ) == 0)
        for _ in 0 ..< 3 {
            counter.recordAdvanced(for: loopKey)
        }
        #expect(counter.count(for: loopKey) == 3)
        #expect(preferredSelectableIndex(
            in: prompt,
            projection: projection,
            selectableIndexes: selectableIndexes,
            repeatCount: 0,
            skillTestPreparationCount: counter.count(for: loopKey)
        ) == 1)

        #expect(counter.count(for: nil) == 0)
        #expect(counter.count(for: loopKey) == 0)
        for _ in 0 ..< 3 {
            counter.recordAdvanced(for: loopKey)
        }
        #expect(counter.count(for: loopKey) == 3)
        #expect(preferredSelectableIndex(
            in: prompt,
            projection: projection,
            selectableIndexes: selectableIndexes,
            repeatCount: 0,
            skillTestPreparationCount: counter.count(for: loopKey)
        ) == 1)
    }

    @Test("Live bot strategy prefers objective progress and avoids resign")
    func botStrategyPrefersObjectivesWithoutUsingLabels() {
        let projection = Self.strategyProjection()
        let prompt = Self.strategyPrompt(choices: [
            QuestionPresentation.Choice(
                sourceIndex: 0,
                kind: .useAbility,
                ability: QuestionPresentation.Ability(
                    cardCode: "c02048",
                    index: 99,
                    type: .action,
                    actions: [.activate, .resign],
                    canBeCancelled: true
                )
            ),
            QuestionPresentation.Choice(sourceIndex: 1, kind: .investigate),
            QuestionPresentation.Choice(sourceIndex: 2, kind: .advanceAct),
        ])

        #expect(preferredSelectableIndex(
            in: prompt,
            projection: projection,
            selectableIndexes: [0, 1, 2],
            repeatCount: 0,
            skillTestPreparationCount: 0
        ) == 2)
    }

    @Test("Live bot strategy breaks repeated player-window ability loops by ending the turn")
    func botStrategyBreaksRepeatedAbilityLoopsWithEndTurn() {
        let projection = Self.strategyProjection()
        let prompt = Self.strategyPrompt(choices: [
            QuestionPresentation.Choice(sourceIndex: 0, kind: .endTurn),
            QuestionPresentation.Choice(
                sourceIndex: 1,
                kind: .useAbility,
                ability: QuestionPresentation.Ability(
                    cardCode: "c09659",
                    index: 1,
                    type: .fast,
                    actions: [.activate],
                    canBeCancelled: false
                )
            ),
        ])

        #expect(preferredSelectableIndex(
            in: prompt,
            projection: projection,
            selectableIndexes: [0, 1],
            repeatCount: 0,
            skillTestPreparationCount: 0
        ) == 1)
        #expect(preferredSelectableIndex(
            in: prompt,
            projection: projection,
            selectableIndexes: [0, 1],
            repeatCount: 5,
            skillTestPreparationCount: 0
        ) == 0)
    }

    @Test("Live bot strategy moves toward clue locations")
    func botStrategyMovesTowardClues() {
        let projection = Self.strategyProjection()
        let blankLocationID = BoardTestFixtures.locationID("000000000902")
        let clueLocationID = BoardTestFixtures.locationID("000000000903")
        let prompt = Self.strategyPrompt(choices: [
            QuestionPresentation.Choice(
                sourceIndex: 3,
                kind: .chooseTarget,
                entity: QuestionPresentation.Entity(
                    kind: .location,
                    id: blankLocationID.codingKey.stringValue
                )
            ),
            QuestionPresentation.Choice(
                sourceIndex: 4,
                kind: .chooseTarget,
                entity: QuestionPresentation.Entity(
                    kind: .location,
                    id: clueLocationID.codingKey.stringValue
                )
            ),
        ])

        #expect(preferredSelectableIndex(
            in: prompt,
            projection: projection,
            selectableIndexes: [3, 4],
            repeatCount: 0,
            skillTestPreparationCount: 0
        ) == 4)
    }

    @Test("Live bot strategy penalizes resign even without objectives")
    func botStrategyPenalizesResignUnconditionally() {
        let projection = Self.strategyProjection()
        let prompt = Self.strategyPrompt(choices: [
            QuestionPresentation.Choice(
                sourceIndex: 0,
                kind: .useAbility,
                ability: QuestionPresentation.Ability(
                    cardCode: "c02048",
                    index: 99,
                    type: .action,
                    actions: [.activate, .resign],
                    canBeCancelled: true
                )
            ),
            QuestionPresentation.Choice(sourceIndex: 1, kind: .opaque),
        ])

        #expect(preferredSelectableIndex(
            in: prompt,
            projection: projection,
            selectableIndexes: [0, 1],
            repeatCount: 0,
            skillTestPreparationCount: 0
        ) == 1)
    }

    @Test("Live bot strategy is seedable for equal-ranked choices")
    func botStrategyUsesSeedForTies() {
        let projection = Self.strategyProjection()
        let prompt = Self.strategyPrompt(choices: [
            QuestionPresentation.Choice(sourceIndex: 8, kind: .gainResource),
            QuestionPresentation.Choice(sourceIndex: 9, kind: .gainResource),
        ])

        #expect(preferredSelectableIndex(
            in: prompt,
            projection: projection,
            selectableIndexes: [8, 9],
            repeatCount: 0,
            skillTestPreparationCount: 0,
            seed: 0
        ) == 8)
        #expect(preferredSelectableIndex(
            in: prompt,
            projection: projection,
            selectableIndexes: [8, 9],
            repeatCount: 0,
            skillTestPreparationCount: 0,
            seed: 1
        ) == 9)
    }

    @Test("Live bot strategy distinguishes clue-bearing and empty investigations")
    func botStrategyInvestigatesOnlyWhenCluesArePresent() {
        let blankLocationID = BoardTestFixtures.locationID("000000000902")
        let prompt = Self.strategyPrompt(choices: [
            QuestionPresentation.Choice(sourceIndex: 3, kind: .investigate),
            QuestionPresentation.Choice(
                sourceIndex: 4,
                kind: .chooseTarget,
                entity: QuestionPresentation.Entity(
                    kind: .location,
                    id: blankLocationID.codingKey.stringValue
                )
            ),
        ])

        #expect(preferredSelectableIndex(
            in: prompt,
            projection: Self.strategyProjection(currentLocationClues: 0),
            selectableIndexes: [3, 4],
            repeatCount: 0,
            skillTestPreparationCount: 0
        ) == 4)
        #expect(preferredSelectableIndex(
            in: prompt,
            projection: Self.strategyProjection(currentLocationClues: 2),
            selectableIndexes: [3, 4],
            repeatCount: 0,
            skillTestPreparationCount: 0
        ) == 3)
    }

    @Test("Live bot strategy scores enemy actions by engagement and failed fights")
    func botStrategyScoresFightAndEvadeByEnemyState() {
        let enemyID = BoardTestFixtures.enemyID("000000000904")
        let enemyEntity = QuestionPresentation.Entity(
            kind: .enemy,
            id: enemyID.codingKey.stringValue
        )
        let prompt = Self.strategyPrompt(choices: [
            QuestionPresentation.Choice(sourceIndex: 5, kind: .fight, entity: enemyEntity),
            QuestionPresentation.Choice(sourceIndex: 6, kind: .evade, entity: enemyEntity),
            QuestionPresentation.Choice(sourceIndex: 7, kind: .gainResource),
        ])

        #expect(preferredSelectableIndex(
            in: prompt,
            projection: Self.strategyProjection(),
            selectableIndexes: [5, 6, 7],
            repeatCount: 0,
            skillTestPreparationCount: 0
        ) == 7)
        #expect(preferredSelectableIndex(
            in: prompt,
            projection: Self.strategyProjection(engagedEnemyID: enemyID),
            selectableIndexes: [5, 6, 7],
            repeatCount: 0,
            skillTestPreparationCount: 0
        ) == 5)
        #expect(preferredSelectableIndex(
            in: prompt,
            projection: Self.strategyProjection(engagedEnemyID: enemyID),
            selectableIndexes: [5, 6, 7],
            repeatCount: 0,
            skillTestPreparationCount: 0,
            failedFightEnemyIDs: [enemyID.codingKey.stringValue]
        ) == 6)
    }

    @Test("Live bot strategy prefers asset soak for lethal damage")
    func botStrategyPrefersAssetSoakForLethalDamage() {
        let investigatorEntity = QuestionPresentation.Entity(kind: .investigator, id: "c01001")
        let assetEntity = QuestionPresentation.Entity(
            kind: .asset,
            id: BoardTestFixtures.assetID("000000000905").codingKey.stringValue
        )
        let prompt = Self.strategyPrompt(choices: [
            QuestionPresentation.Choice(
                sourceIndex: 0,
                kind: .assignDamage,
                entity: investigatorEntity
            ),
            QuestionPresentation.Choice(sourceIndex: 1, kind: .assignDamage, entity: assetEntity),
        ])

        #expect(preferredSelectableIndex(
            in: prompt,
            projection: Self.strategyProjection(investigatorTokens: [
                TokenCount(token: "Damage", count: 8),
            ]),
            selectableIndexes: [0, 1],
            repeatCount: 0,
            skillTestPreparationCount: 0
        ) == 1)
    }

    @Test("Live bot strategy ignores non-selectable objective choices")
    func botStrategyNeverReturnsNonSelectableIndex() {
        let projection = Self.strategyProjection()
        let prompt = Self.strategyPrompt(choices: [
            QuestionPresentation.Choice(sourceIndex: 0, kind: .advanceAct, selectable: false),
            QuestionPresentation.Choice(sourceIndex: 1, kind: .endTurn),
        ])

        #expect(preferredSelectableIndex(
            in: prompt,
            projection: projection,
            selectableIndexes: [1],
            repeatCount: 0,
            skillTestPreparationCount: 0
        ) == 1)
    }

    @Test("Live bot answer selection call site uses actionable choices")
    @MainActor
    func selectAnswerCallSiteFiltersUnresolvedLabelsBeforeStrategy() throws {
        let prompt = try Self.semanticChoicePrompt(
            questionVersion: 82,
            choices: [
                QuestionPresentation.Choice(
                    sourceIndex: 0,
                    kind: .advanceAct,
                    label: QuestionPresentation.Label(kind: .embeddedI18n, text: "$blocked")
                ),
                QuestionPresentation.Choice(sourceIndex: 1, kind: .gainResource),
            ]
        )
        let projection = Self.strategyProjection()

        #expect(liveHarnessSelectableChoiceIndexes(prompt: prompt, projection: projection) == [1])
        let selected = try Self.liveBot(diagnosticBypassUnsupported: false).selectAnswerForTesting(
            prompt: prompt,
            projection: projection,
            repeatCount: 0,
            skillTestPreparationCount: 0,
            failedFightEnemyIDs: []
        )
        #expect(Self.selectedChoiceIndex(in: selected) == 1)
        #expect(selected.chosenChoiceKind == QuestionPresentation.ChoiceKind.gainResource.rawValue)
    }

    @Test("Live bot sends source index when completion choices display last")
    @MainActor
    func selectAnswerSendsSourceIndexWhenDisplayOrderDiffers() throws {
        let prompt = try Self.semanticChoicePrompt(
            questionVersion: 83,
            questionKind: .chooseOneAtATime,
            choices: [
                QuestionPresentation.Choice(
                    sourceIndex: 0,
                    kind: .endTurn,
                    completesSelection: true
                ),
                QuestionPresentation.Choice(sourceIndex: 1, kind: .gainResource),
                QuestionPresentation.Choice(sourceIndex: 2, kind: .drawCard),
            ]
        )
        let projection = Self.strategyProjection()

        #expect(prompt.choices.map(\.index) == [0, 1, 2])
        #expect(prompt.displayOrderedChoices().map(\.index) == [1, 2, 0])
        #expect(
            liveHarnessSelectableChoiceIndexes(prompt: prompt, projection: projection) == [1, 2, 0]
        )
        let selected = try Self.liveBot(diagnosticBypassUnsupported: false).selectAnswerForTesting(
            prompt: prompt,
            projection: projection,
            repeatCount: 0,
            skillTestPreparationCount: 0,
            failedFightEnemyIDs: []
        )
        #expect(Self.selectedChoiceIndex(in: selected) == 1)
        #expect(selected.chosenChoiceKind == QuestionPresentation.ChoiceKind.gainResource.rawValue)
    }

    @Test("Diagnostic bypass falls back to semantic selectable choices only when enabled")
    @MainActor
    func diagnosticBypassUsesSemanticSelectableFallbackOnlyWhenEnabled() throws {
        let prompt = try Self.semanticChoicePrompt(
            questionVersion: 81,
            choices: [QuestionPresentation.Choice(
                sourceIndex: 0,
                kind: .advanceAct,
                label: QuestionPresentation.Label(kind: .embeddedI18n, text: "$blocked")
            )]
        )
        let projection = Self.strategyProjection()

        #expect(liveHarnessSelectableChoiceIndexes(prompt: prompt, projection: projection) == [])
        do {
            _ = try Self.liveBot(diagnosticBypassUnsupported: false).selectAnswerForTesting(
                prompt: prompt,
                projection: projection,
                repeatCount: 0,
                skillTestPreparationCount: 0,
                failedFightEnemyIDs: []
            )
            Issue.record("Expected unresolved label selection to fail without diagnostic bypass")
        } catch let error as PlaythroughError {
            #expect(error.description == "no selectable choice at q81 / ChooseOne")
        }

        let selected = try Self.liveBot(diagnosticBypassUnsupported: true).selectAnswerForTesting(
            prompt: prompt,
            projection: projection,
            repeatCount: 0,
            skillTestPreparationCount: 0,
            failedFightEnemyIDs: []
        )
        #expect(Self.selectedChoiceIndex(in: selected) == 0)
        #expect(selected.note == "diagnostic bypass selectable choice 0")
    }

    @Test("Live bot strategy favors payable act objectives")
    func botStrategyFavorsPayableActObjectives() {
        let projection = Self.strategyProjection(
            currentLocationClues: 2,
            investigatorTokens: [TokenCount(token: "Clue", count: 2)],
            actAdvanceCost: RuntimeCost(tag: "GroupClueCost", contents: nil)
        )
        let prompt = Self.strategyPrompt(choices: [
            QuestionPresentation.Choice(
                sourceIndex: 0,
                kind: .useAbility,
                ability: QuestionPresentation.Ability(
                    cardCode: "c01108",
                    index: 1,
                    type: .objective,
                    actions: [.activate],
                    canBeCancelled: true
                )
            ),
            QuestionPresentation.Choice(sourceIndex: 1, kind: .advanceAgenda),
        ])

        #expect(preferredSelectableIndex(
            in: prompt,
            projection: projection,
            selectableIndexes: [0, 1],
            repeatCount: 0,
            skillTestPreparationCount: 0
        ) == 0)
    }

    @Test("Live bot tracking clears successful fights before later failed tests")
    func botFightTrackingDoesNotCarrySuccessIntoLaterFailure() {
        let enemyID = BoardTestFixtures.enemyID("000000000904").codingKey.stringValue
        var pendingFightEnemyID: String? = enemyID
        var failedFightEnemyIDs: Set<String> = []

        updatePendingFightOutcome(
            skillTest: Self.skillTestProjection(succeeded: true),
            pendingFightEnemyID: &pendingFightEnemyID,
            failedFightEnemyIDs: &failedFightEnemyIDs
        )
        #expect(pendingFightEnemyID == nil)
        #expect(failedFightEnemyIDs.isEmpty)

        updatePendingFightOutcome(
            skillTest: Self.skillTestProjection(succeeded: false),
            pendingFightEnemyID: &pendingFightEnemyID,
            failedFightEnemyIDs: &failedFightEnemyIDs
        )
        #expect(failedFightEnemyIDs.isEmpty)
    }

    @Test("Live bot strategy plays assets and commits before starting tests")
    func botStrategyPlaysAssetsAndCommitsBeforeStartingTests() {
        let cardEntity = QuestionPresentation.Entity(
            kind: .card,
            id: BoardTestFixtures.cardID("000000000906").codingKey.stringValue
        )
        let playPrompt = Self.strategyPrompt(choices: [
            QuestionPresentation.Choice(sourceIndex: 0, kind: .chooseTarget, entity: cardEntity),
            QuestionPresentation.Choice(sourceIndex: 1, kind: .gainResource),
            QuestionPresentation.Choice(sourceIndex: 2, kind: .investigate),
        ])
        let commitPrompt = Self.strategyPrompt(choices: [
            QuestionPresentation.Choice(sourceIndex: 0, kind: .chooseTarget, entity: cardEntity),
            QuestionPresentation.Choice(sourceIndex: 1, kind: .startSkillTest),
        ])

        #expect(preferredSelectableIndex(
            in: playPrompt,
            projection: Self.strategyProjection(investigatorTokens: [
                TokenCount(token: "Resource", count: 3),
            ]),
            selectableIndexes: [0, 1, 2],
            repeatCount: 0,
            skillTestPreparationCount: 0
        ) == 0)
        #expect(preferredSelectableIndex(
            in: commitPrompt,
            projection: Self.strategyProjection(),
            selectableIndexes: [0, 1],
            repeatCount: 0,
            skillTestPreparationCount: 0
        ) == 0)
        #expect(preferredSelectableIndex(
            in: commitPrompt,
            projection: Self.strategyProjection(),
            selectableIndexes: [0, 1],
            repeatCount: 0,
            skillTestPreparationCount: 1
        ) == 1)
    }

    @Test("Live trace prompt encoding includes board progress diagnostics")
    // swiftlint:disable:next function_body_length
    func tracePromptEncodingIncludesBoardProgressDiagnostics() throws {
        let investigatorID = BoardTestFixtures.investigatorID("c01001")
        let ownerID = BoardTestFixtures.playerID()
        let actID = BoardTestFixtures.actID("c01108")
        let agendaID = BoardTestFixtures.agendaID("c01109")
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            investigators: [
                investigatorID: BoardTestFixtures.investigator(
                    id: investigatorID,
                    health: 7,
                    sanity: 6,
                    remainingActions: 1,
                    tokens: [
                        TokenCount(token: "Damage", count: 2),
                        TokenCount(token: "Horror", count: 1),
                        TokenCount(token: "Clue", count: 3),
                        TokenCount(token: "Resource", count: 4),
                    ],
                    playerID: ownerID
                ),
            ],
            acts: [
                actID: BoardTestFixtures.act(
                    id: actID,
                    sequence: ActSequence(step: 2, side: .sideB),
                    flipped: true,
                    advanceCost: RuntimeCost(tag: "GroupClueCost", contents: nil),
                    tokens: [TokenCount(token: "Clue", count: 4)]
                ),
            ],
            agendas: [
                agendaID: BoardTestFixtures.agenda(
                    id: agendaID,
                    sequence: AgendaSequence(side: .sideB, step: 3),
                    doom: 2,
                    doomThreshold: .staticValue(6),
                    flipped: false
                ),
            ],
            playerOrder: [investigatorID],
            activeInvestigatorID: investigatorID,
            leadInvestigatorID: investigatorID
        ))
        let prompt = Self.prompt(
            questionVersion: 42,
            rawQuestion: .object([
                "tag": .string("ChooseOne"),
                "choices": .array([]),
            ])
        )
        let record = PlaythroughTraceRecord.prompt(
            investigator: InvestigatorFixture.core[0],
            gameID: BoardTestFixtures.gameID(),
            scenario: "The Gathering",
            prompt: prompt,
            projection: projection,
            repeatCount: 0,
            selectedAnswer: nil,
            submission: nil,
            outcome: .submittedAndAdvanced("test"),
            serverFeedback: nil
        )
        let encoded = try ContractJSON.decode(
            JSONValue.self,
            from: ContractJSON.encode(record)
        )

        guard case let .object(root) = encoded,
              case let .object(promptPayload)? = root["prompt"],
              case let .object(investigatorStatus)? = promptPayload["investigatorStatus"],
              case let .array(actProgress)? = promptPayload["actProgress"],
              case let .object(act)? = actProgress.first,
              case let .array(agendaProgress)? = promptPayload["agendaProgress"],
              case let .object(agenda)? = agendaProgress.first
        else {
            Issue.record("Expected encoded prompt diagnostics")
            return
        }

        #expect(investigatorStatus["investigatorID"] == .string("c01001"))
        #expect(investigatorStatus["damage"] == .number(.integer(2)))
        #expect(investigatorStatus["horror"] == .number(.integer(1)))
        #expect(investigatorStatus["clues"] == .number(.integer(3)))
        #expect(investigatorStatus["resources"] == .number(.integer(4)))
        #expect(investigatorStatus["health"] == .number(.integer(7)))
        #expect(investigatorStatus["sanity"] == .number(.integer(6)))
        #expect(investigatorStatus["remainingActions"] == .number(.integer(1)))
        #expect(investigatorStatus["defeated"] == .bool(false))
        #expect(investigatorStatus["resigned"] == .bool(false))

        #expect(act["id"] == .string("c01108"))
        #expect(act["cardCode"] == .string("c01108"))
        #expect(act["sequence"] == .string("2B"))
        #expect(act["flipped"] == .bool(true))
        #expect(act["advanceCostSummary"] == .string("Group Clue Cost"))
        #expect(act["clues"] == .number(.integer(4)))

        #expect(agenda["id"] == .string("c01109"))
        #expect(agenda["cardCode"] == .string("c01109"))
        #expect(agenda["sequence"] == .string("3B"))
        #expect(agenda["doom"] == .number(.integer(2)))
        #expect(agenda["doomThresholdSummary"] == .string("6"))
        #expect(agenda["flipped"] == .bool(false))
    }

    @Test("Live coverage report summarizes resolutions, prompts and selections")
    func playthroughCoverageReportSummarizesRun() {
        let prompt = Self.strategyPrompt(choices: [
            QuestionPresentation.Choice(sourceIndex: 0, kind: .advanceAct),
            QuestionPresentation.Choice(sourceIndex: 1, kind: .investigate),
        ])
        var accumulator = PlaythroughCoverageAccumulator()
        accumulator.recordPrompt(prompt)
        accumulator.recordSelection(
            scenario: "c01104",
            answer: SelectedBotAnswer(
                answer: .choice(0),
                note: "advance act",
                chosenChoiceKind: QuestionPresentation.ChoiceKind.advanceAct.rawValue
            )
        )
        let report = accumulator.report(scenarioOutcomes: [
            "c01104": "resolution {\"contents\":1,\"tag\":\"Resolution\"}",
            "c01120": "resolution {\"tag\":\"NoResolution\"}",
            "c01142": "completed without recorded resolution",
            "scenario-only": "gameState IsOver",
        ])

        #expect(report.nonNoResolutionScenarioIDs == ["c01104"])
        #expect(report.actAdvanceSelectionsByScenario == ["c01104": 1])
        #expect(report.rawQuestionKindsSeen == ["ChooseOne"])
        #expect(report.presentationKindsSeen == ["chooseOne"])
        #expect(report.choiceKindsSeen == ["advanceAct", "investigate"])
        #expect(report.selectionCounts == ["advanceAct": 1])
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

    private static func prompt(
        questionVersion: Int,
        rawQuestion: JSONValue,
        questionState: BasicChoiceQuestionState = .updateRequired(tag: nil),
        questionPresentation: QuestionPresentation? = nil
    ) -> BasicChoicePromptPresentation {
        BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: questionVersion,
                rawQuestion: rawQuestion,
                questionPresentation: questionPresentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: questionState,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    private static func capturedForgottenAgeSupplyPrompt(
        named name: String
    ) throws -> BasicChoicePromptPresentation {
        let fixture = try capturedForgottenAgePrompt(named: name)
        return prompt(
            questionVersion: fixture.questionVersion,
            rawQuestion: fixture.rawQuestion,
            questionPresentation: fixture.questionPresentation
        )
    }

    private static func capturedForgottenAgePrompt(
        named name: String
    ) throws -> CapturedLivePromptFixture {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/LiveForgottenAgePlaythrough"
        ))
        return try ContractJSON.decode(
            CapturedLivePromptFixture.self,
            from: Data(contentsOf: url)
        )
    }

    private static func destinyDrawing(
        scenario: String,
        arcana: String,
        facing: QuestionPresentation.TarotCard.Facing
    ) -> QuestionPresentation.DestinyDrawing {
        QuestionPresentation.DestinyDrawing(
            scenario: .string(scenario),
            tarot: QuestionPresentation.TarotCard(facing: facing, arcana: arcana)
        )
    }

    private static func capturedCircleUndonePrompt(
        named name: String
    ) throws -> CapturedLivePromptFixture {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/LiveCircleUndonePlaythrough"
        ))
        return try ContractJSON.decode(
            CapturedLivePromptFixture.self,
            from: Data(contentsOf: url)
        )
    }

    private static func promptFromFixture(
        _ fixture: CapturedLivePromptFixture,
        model: AppModel
    ) throws -> BasicChoicePromptPresentation {
        let bound = try fixture.questionPresentation.bind(
            to: fixture.rawQuestion,
            expectedQuestionVersion: fixture.questionVersion
        )
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: fixture.questionVersion,
                rawQuestion: fixture.rawQuestion,
                questionPresentation: fixture.questionPresentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: .updateRequired(tag: "ChooseAmounts"),
            semanticPresentation: bound,
            promptLabelResolutions: model.promptLabelResolutions(
                for: fixture.questionPresentation
            ),
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    private static func appModelWithCatalog(
        entries: [String: String]
    ) async throws -> AppModel {
        let documents = try SyntheticLocaleCatalogDocuments.make(
            pack: "choice",
            entryKeys: entries.keys.sorted(),
            chunkEntries: localeCatalogChunkEntries(entries)
        )
        let model = AppModel(
            profileStore: FakeServerProfileStore(
                profiles: [documents.profile], selectedID: documents.profile.id
            ),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.compatible(
                capabilities: [LocaleCatalogLimits.capabilityIdentifier],
                localeCatalog: documents.advertisement
            ))),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            localeCatalogLoader: documents.loader(),
            preferredLanguagesProvider: LiveHarnessPreferredLanguages(preferredLanguages: ["en"])
        )
        await model.flowTask?.value
        await model.localeCatalogTask?.value
        return model
    }

    private static func localeCatalogChunkEntries(
        _ entries: [String: String]
    ) throws -> String {
        let pairs = try entries.keys.sorted().map { key in
            try "\(jsonLiteral(key)):\(messageEntryJSON(text: entries[key] ?? ""))"
        }
        return "{\(pairs.joined(separator: ","))}"
    }

    private static func messageEntryJSON(text: String) throws -> String {
        try "{\"form\":\"message\",\"nodes\":[{\"type\":\"text\",\"value\":"
            + jsonLiteral(text) + "}],\"variables\":[]}"
    }

    private static func jsonLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        return try #require(String(data: data, encoding: .utf8))
    }

    private static func assertPlainLabelDoesNotUseChoiceNamespace(
        model: AppModel
    ) throws {
        let rawQuestion = Self.rawLabelQuestion("$supplyPoints")
        let presentation = QuestionPresentation(
            protocolVersion: QuestionPresentation.supportedProtocolVersion,
            questionVersion: 1,
            questionKind: .chooseOne,
            choiceCount: 1,
            choices: [QuestionPresentation.Choice(
                sourceIndex: 0,
                kind: .localizedLabel,
                label: QuestionPresentation.Label(
                    kind: .embeddedI18n,
                    text: "$supplyPoints"
                )
            )]
        )
        let bound = try presentation.bind(to: rawQuestion, expectedQuestionVersion: 1)
        #expect(model.choiceLabelResolutions(
            for: nil,
            semanticPresentation: bound
        )[0] == .unavailable(.missingKey))
    }

    private static func rawLabelQuestion(_ label: String) -> JSONValue {
        .object([
            "tag": .string("ChooseOne"),
            "choices": .array([
                .object([
                    "tag": .string("Label"),
                    "label": .string(label),
                    "messages": .array([]),
                ]),
            ]),
        ])
    }

    private static func amountNamespacePresentation() -> QuestionPresentation {
        QuestionPresentation(
            protocolVersion: QuestionPresentation.supportedProtocolVersion,
            questionVersion: 2,
            questionKind: .chooseAmounts,
            choiceCount: 0,
            choices: [],
            answer: .amounts,
            label: QuestionPresentation.Label(kind: .embeddedI18n, text: "$x"),
            target: .max(3),
            amountChoices: [
                QuestionPresentation.AmountChoice(
                    choiceID: "x-row", label: "$x", minBound: 0, maxBound: 1
                ),
                QuestionPresentation.AmountChoice(
                    choiceID: "dotted-row", label: "$foo.bar", minBound: 0, maxBound: 1
                ),
                QuestionPresentation.AmountChoice(
                    choiceID: "missing-row", label: "$missing", minBound: 0, maxBound: 1
                ),
            ]
        )
    }

    private static func selectedBotIndex(in prompt: BasicChoicePromptPresentation) -> Int {
        let selectableIndexes = prompt.identity.questionPresentation?.choices.compactMap {
            $0.selectable ? $0.sourceIndex : nil
        } ?? []
        return preferredSelectableIndex(
            in: prompt,
            projection: strategyProjection(),
            selectableIndexes: selectableIndexes,
            repeatCount: 0,
            skillTestPreparationCount: 0
        )
    }

    private static func selectedChoiceIndex(in answer: SelectedBotAnswer) -> Int? {
        guard case let .choice(index) = answer.answer else { return nil }
        return index
    }

    @MainActor
    private static func liveBot(
        diagnosticBypassUnsupported: Bool
    ) throws -> LivePlaythroughBot {
        let investigator = InvestigatorFixture.core[0]
        return try LivePlaythroughBot(
            model: AppModel(
                profileStore: FakeServerProfileStore(),
                tokenStore: FakeTokenStore(),
                cleanupPendingStore: FakeTokenCleanupPendingStore()
            ),
            lifecycle: GameLifecycleService(),
            profile: .hosted,
            token: "test-token",
            gameID: BoardTestFixtures.gameID(),
            investigator: investigator,
            deck: deckFixture(for: investigator),
            replacementDecksByCode: [:],
            trace: PlaythroughTraceRecorder(path: "/tmp/arkham-test-live-bot-trace.jsonl"),
            diagnosticBypassUnsupported: diagnosticBypassUnsupported,
            strategySeed: 0
        )
    }

    private static func semanticChoicePrompt(
        questionVersion: Int,
        questionKind: QuestionPresentation.Kind = .chooseOne,
        choices: [QuestionPresentation.Choice],
        selection: QuestionPresentation.Selection? = nil
    ) throws -> BasicChoicePromptPresentation {
        let rawTag = rawQuestionTag(for: questionKind)
        let rawQuestion: JSONValue = .object([
            "tag": .string(rawTag),
            "choices": .array(choices.map { _ in
                .object(["tag": .string("Label"), "label": .string("$choice")])
            }),
        ])
        let presentation = QuestionPresentation(
            protocolVersion: QuestionPresentation.supportedProtocolVersion,
            questionVersion: questionVersion,
            questionKind: questionKind,
            choiceCount: choices.count,
            choices: choices,
            selection: selection
        )
        let bound = try presentation.bind(
            to: rawQuestion,
            expectedQuestionVersion: questionVersion
        )
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: questionVersion,
                rawQuestion: rawQuestion,
                questionPresentation: presentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: .updateRequired(tag: rawTag),
            semanticPresentation: bound,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    private static func rawQuestionTag(for questionKind: QuestionPresentation.Kind) -> String {
        switch questionKind {
        case .chooseOneAtATime: "ChooseOneAtATime"
        default: "ChooseOne"
        }
    }

    private static func semanticPresentation(
        choiceKind: QuestionPresentation.ChoiceKind
    ) -> QuestionPresentation {
        QuestionPresentation(
            protocolVersion: QuestionPresentation.supportedProtocolVersion,
            questionVersion: 7,
            questionKind: .chooseOne,
            choiceCount: 1,
            choices: [QuestionPresentation.Choice(sourceIndex: 0, kind: choiceKind)]
        )
    }

    private static func strategyPrompt(
        choices: [QuestionPresentation.Choice]
    ) -> BasicChoicePromptPresentation {
        let rawQuestion: JSONValue = .object([
            "tag": .string("ChooseOne"),
            "choices": .array(choices.map { _ in .object(["tag": .string("Label")]) }),
        ])
        return prompt(
            questionVersion: 42,
            rawQuestion: rawQuestion,
            questionPresentation: QuestionPresentation(
                protocolVersion: QuestionPresentation.supportedProtocolVersion,
                questionVersion: 42,
                questionKind: .chooseOne,
                choiceCount: choices.count,
                choices: choices
            )
        )
    }

    private static func strategyProjection(
        currentLocationClues: Int = 0,
        currentLocationRevealed: Bool = true,
        investigatorTokens: [TokenCount] = [],
        engagedEnemyID: EnemyID? = nil,
        actAdvanceCost: RuntimeCost? = nil
    ) -> BoardProjection {
        let investigatorID = BoardTestFixtures.investigatorID("c01001")
        let currentLocationID = BoardTestFixtures.locationID("000000000901")
        let blankLocationID = BoardTestFixtures.locationID("000000000902")
        let clueLocationID = BoardTestFixtures.locationID("000000000903")
        let actID = BoardTestFixtures.actID("c01108")
        let investigator = BoardTestFixtures.investigator(
            id: investigatorID,
            engagedEnemies: engagedEnemyID.map { [$0] } ?? [],
            tokens: investigatorTokens,
            playerID: BoardTestFixtures.playerID()
        )
        let currentTokens = currentLocationClues > 0
            ? [TokenCount(token: "Clue", count: currentLocationClues)]
            : []
        return BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            locations: [
                (currentLocationID, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: currentLocationID,
                    revealed: currentLocationRevealed,
                    tokens: currentTokens,
                    connectedLocations: [blankLocationID, clueLocationID],
                    investigators: [investigatorID]
                ))),
                (blankLocationID, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: blankLocationID,
                    revealed: false,
                    connectedLocations: [currentLocationID]
                ))),
                (clueLocationID, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: clueLocationID,
                    tokens: [TokenCount(token: "Clue", count: 2)],
                    connectedLocations: [currentLocationID]
                ))),
            ],
            investigators: [investigatorID: investigator],
            acts: [actID: BoardTestFixtures.act(id: actID, advanceCost: actAdvanceCost)],
            playerOrder: [investigatorID],
            activeInvestigatorID: investigatorID,
            leadInvestigatorID: investigatorID
        ))
    }

    private static func skillTestPreparationPrompt(
        questionVersion: Int
    ) throws -> BasicChoicePromptPresentation {
        let rawQuestion: JSONValue = .object([
            "tag": .string("ChooseOne"),
            "choices": .array([
                .object(["tag": .string("UnknownPreparationChoice")]),
                .object([
                    "tag": .string("StartSkillTestButton"),
                    "investigatorId": .string("c01001"),
                ]),
            ]),
        ])
        return prompt(
            questionVersion: questionVersion,
            rawQuestion: rawQuestion,
            questionState: BasicChoiceParser.parseQuestion(rawQuestion)
        )
    }

    private static func skillTestProjection(succeeded: Bool) -> BoardSkillTestProjection {
        .available(BoardSkillTestSummary(
            investigatorID: BoardTestFixtures.investigatorID("c01001"),
            step: .applyResults,
            modifiedSkillValue: succeeded ? 3 : 1,
            modifiedDifficulty: 2,
            verdict: BoardSkillTestVerdict(
                succeeded: succeeded,
                amount: 1,
                automatic: false
            ),
            result: nil
        ))
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
        var coverage: PlaythroughCoverageReport = .empty
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
                diagnosticBypassUnsupported: Self.diagnosticBypassUnsupported,
                strategySeed: configuration.botSeed
            )
            let outcome = try await bot.driveUntilServerCompletion()
            scenarioOutcomes = outcome.scenarioOutcomes
            promptFailure = outcome.promptFailure
            coverage = outcome.coverage
            if outcome.reachedServerCompletion {
                return PlaythroughResult(
                    investigator: investigator,
                    status: .passed,
                    scenarioOutcomes: scenarioOutcomes,
                    promptFailure: nil,
                    finalGameID: gameID.rawValue.uuidString.lowercased(),
                    coverage: coverage
                )
            }
            let reason = promptFailure?.description
                ?? "playthrough stopped without server gameState IsOver"
            return PlaythroughResult(
                investigator: investigator,
                status: .failed(reason),
                scenarioOutcomes: scenarioOutcomes,
                promptFailure: promptFailure,
                finalGameID: gameID.rawValue.uuidString.lowercased(),
                coverage: coverage
            )
        } catch {
            return PlaythroughResult(
                investigator: investigator,
                status: .failed(String(describing: error)),
                scenarioOutcomes: scenarioOutcomes,
                promptFailure: promptFailure,
                finalGameID: nil,
                coverage: coverage
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
        for fixture in InvestigatorFixture.replacementPool where fixture.code != investigator.code {
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
            "Bot strategy seed: \(configuration.botSeed)",
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
        appendCoverageReport(to: &lines, results: results)
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

    private func appendCoverageReport(
        to lines: inout [String], results: [PlaythroughResult]
    ) {
        lines.append("")
        lines.append("## Coverage")
        lines.append("")
        lines.append([
            "Investigator",
            "Resolutions reached per scenario",
            "Non-NoResolution scenarios",
            "Act advances selected",
            "Agenda advances selected",
            "Raw question kinds seen",
            "Semantic presentation kinds seen",
            "Semantic choice kinds seen",
            "Selection counts (selected)",
        ].joined(separator: " | ").withMarkdownTablePipes())
        lines.append(Array(repeating: "---", count: 9).joined(separator: " | ")
            .withMarkdownTablePipes())
        for result in results {
            let coverage = result.coverage
            lines.append([
                "\(result.investigator.name) (\(result.investigator.code))",
                coverage.scenarioResolutionSummary,
                listSummary(coverage.nonNoResolutionScenarioIDs),
                coverage.actAdvanceSummary,
                coverage.agendaAdvanceSummary,
                coverage.questionKindsSummary,
                coverage.presentationKindsSummary,
                coverage.choiceKindsSummary,
                coverage.selectionCountsSummary,
            ].map { $0.replacingOccurrences(of: "|", with: "\\|") }
                .joined(separator: " | ")
                .withMarkdownTablePipes())
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
    let strategySeed: UInt64

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func driveUntilServerCompletion() async throws -> BotOutcome {
        var repeatedQuestionShapes: [String: Int] = [:]
        var skillTestPreparationCounter = SkillTestPreparationLoopCounter()
        var coverage = PlaythroughCoverageAccumulator()
        var pendingFightEnemyID: String?
        var failedFightEnemyIDs: Set<String> = []
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
                    promptFailure: nil,
                    coverage: coverage.report(scenarioOutcomes: currentOutcomes)
                )
            }

            let projection: BoardProjection
            do {
                projection = try await waitForProjection()
                updatePendingFightOutcome(
                    skillTest: projection.skillTest,
                    pendingFightEnemyID: &pendingFightEnemyID,
                    failedFightEnemyIDs: &failedFightEnemyIDs
                )
            } catch let error as PlaythroughError {
                guard case .timedOut = error else { throw error }
                return try recordRunTimedOut(
                    reason: error.description,
                    snapshot: envelope.game,
                    scenarioOutcomes: currentOutcomes,
                    coverage: coverage.report(scenarioOutcomes: currentOutcomes)
                )
            }
            guard let prompt = model.basicChoicePresentation(for: gameID) else {
                _ = skillTestPreparationCounter.count(for: nil)
                try await Task.sleep(for: .milliseconds(200))
                continue
            }
            let scenario = currentScenarioCode(projection: projection, snapshot: envelope.game)
            coverage.recordPrompt(prompt)
            try await captureReplacementPromptIfRequested(prompt: prompt, projection: projection)
            let repeatKey = coverageRepeatKey(scenario: scenario, prompt: prompt)
            let repeatCount = repeatedQuestionShapes[repeatKey, default: 0]
            let skillTestPreparationKey = skillTestPreparationLoopKey(
                scenario: scenario,
                prompt: prompt
            )
            let skillTestPreparationCount = skillTestPreparationCounter.count(
                for: skillTestPreparationKey
            )
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
                    promptFailure: failure,
                    coverage: coverage.report(scenarioOutcomes: currentOutcomes)
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
                    promptFailure: failure,
                    coverage: coverage.report(scenarioOutcomes: currentOutcomes)
                )
            }

            let selectedAnswer: SelectedBotAnswer
            do {
                selectedAnswer = try selectAnswer(
                    prompt: prompt,
                    projection: projection,
                    repeatCount: repeatCount,
                    skillTestPreparationCount: skillTestPreparationCount,
                    failedFightEnemyIDs: failedFightEnemyIDs
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
                    promptFailure: failure,
                    coverage: coverage.report(scenarioOutcomes: currentOutcomes)
                )
            }

            coverage.recordSelection(scenario: scenario, answer: selectedAnswer)
            let selectedFight = selectedAnswer.chosenChoiceKind
                == QuestionPresentation.ChoiceKind.fight.rawValue
            let selectedEnemy = selectedAnswer.chosenEntityKind
                == QuestionPresentation.EntityKind.enemy.rawValue
            if selectedFight, selectedEnemy {
                pendingFightEnemyID = selectedAnswer.chosenEntityID
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
                    skillTestPreparationCounter.recordAdvanced(for: skillTestPreparationKey)
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
                        promptFailure: failure,
                        coverage: coverage.report(scenarioOutcomes: currentOutcomes)
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
                    promptFailure: failure,
                    coverage: coverage.report(scenarioOutcomes: currentOutcomes)
                )
            }
        }
        let envelope = try await lifecycle.getGame(gameID, on: profile, token: token)
        let currentOutcomes = scenarioOutcomes(from: envelope.game)
        return try recordRunTimedOut(
            reason: "playthrough timed out before server gameState IsOver",
            snapshot: envelope.game,
            scenarioOutcomes: currentOutcomes,
            coverage: coverage.report(scenarioOutcomes: currentOutcomes)
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
        scenarioOutcomes: [String: String],
        coverage: PlaythroughCoverageReport
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
            promptFailure: failure,
            coverage: coverage
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

    fileprivate func selectAnswerForTesting(
        prompt: BasicChoicePromptPresentation,
        projection: BoardProjection,
        repeatCount: Int,
        skillTestPreparationCount: Int,
        failedFightEnemyIDs: Set<String>
    ) throws -> SelectedBotAnswer {
        try selectAnswer(
            prompt: prompt,
            projection: projection,
            repeatCount: repeatCount,
            skillTestPreparationCount: skillTestPreparationCount,
            failedFightEnemyIDs: failedFightEnemyIDs
        )
    }

    // swiftlint:disable:next function_body_length
    private func selectAnswer(
        prompt: BasicChoicePromptPresentation,
        projection: BoardProjection,
        repeatCount: Int,
        skillTestPreparationCount: Int,
        failedFightEnemyIDs: Set<String>
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
        if let drawings = prompt.pickDestinyDrawings {
            return SelectedBotAnswer(
                answer: .pickDestiny(pickDestinyBotSelection(drawings)),
                note: "reverse half of the published tarot drawing",
                chosenChoiceKind: nil
            )
        }
        let travelAction = prompt.scarletKeysTravelPrompt.flatMap(preferredScarletKeysTravelAction)
        if let action = travelAction {
            return SelectedBotAnswer(
                answer: .campaignSpecific(action.payload),
                note: "Scarlet Keys world-map \(action.kind.rawValue) to \(action.locationID)",
                chosenChoiceKind: "scarletKeysTravel"
            )
        }
        let actionableIndexes = liveHarnessSelectableChoiceIndexes(
            prompt: prompt,
            projection: projection
        )
        let isDiagnosticBypassSelection = actionableIndexes.isEmpty
            && canDiagnosticBypassUnsupported(prompt)
        let selectableIndexes = isDiagnosticBypassSelection
            ? liveHarnessDiagnosticBypassSelectableChoiceIndexes(prompt: prompt)
            : actionableIndexes
        guard !selectableIndexes.isEmpty else {
            throw PlaythroughError.noSelectableChoice(
                version: prompt.questionVersion,
                tag: describeRawQuestionTag(prompt.identity.rawQuestion)
            )
        }
        let selectedIndex = preferredSelectableIndex(
            in: prompt,
            projection: projection,
            selectableIndexes: selectableIndexes,
            repeatCount: repeatCount,
            skillTestPreparationCount: skillTestPreparationCount,
            seed: strategySeed,
            failedFightEnemyIDs: failedFightEnemyIDs
        )
        let chosenChoice = prompt.identity.questionPresentation?.choices.first {
            $0.sourceIndex == selectedIndex
        }
        return SelectedBotAnswer(
            answer: .choice(selectedIndex),
            note: isDiagnosticBypassSelection
                ? "diagnostic bypass selectable choice \(selectedIndex)"
                : "selectable choice \(selectedIndex)",
            chosenChoiceKind: chosenChoice?.kind.rawValue,
            chosenEntityKind: chosenChoice?.entity?.kind.rawValue,
            chosenEntityID: chosenChoice?.entity?.id
        )
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
        case let .pickDestiny(drawings):
            result = await model.submitPickDestinyAnswer(prompt.identity, drawings: drawings)
        case let .campaignSpecific(contents):
            result = await model.submitCampaignSpecificAnswer(prompt.identity, contents: contents)
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
            if basicChoicePromptAdvanced(from: identity, to: current) {
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
        LiveChooseDeckQuestion.matches(prompt.identity.rawQuestion)
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
    case pickDestiny([QuestionPresentation.DestinyDrawing])
    case campaignSpecific(JSONValue)
    case savedDeck(Deck)
    case replacementDeck(originalInvestigatorID: String, deck: Deck)
    case skipDeckUpgrade(investigatorID: String)
}

private struct SelectedBotAnswer: Sendable {
    let answer: BotAnswer
    let note: String
    let chosenChoiceKind: String?
    let chosenEntityKind: String?
    let chosenEntityID: String?

    init(
        answer: BotAnswer,
        note: String,
        chosenChoiceKind: String?,
        chosenEntityKind: String? = nil,
        chosenEntityID: String? = nil
    ) {
        self.answer = answer
        self.note = note
        self.chosenChoiceKind = chosenChoiceKind
        self.chosenEntityKind = chosenEntityKind
        self.chosenEntityID = chosenEntityID
    }
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
    var coverageKind: String {
        switch self {
        case .choice: "Answer"
        case .amounts: "AmountsAnswer"
        case .paymentAmounts: "PaymentAmountsAnswer"
        case .exchangeAmount: "ExchangeAmountsAnswer"
        case .continueCampaign: "CampaignStepAnswer"
        case .pickDestiny: "PickDestinyAnswer"
        case .campaignSpecific: "CampaignSpecificAnswer"
        case .savedDeck: "DeckAnswer"
        case .replacementDeck: "ReplacementDeck"
        case .skipDeckUpgrade: "SkipDeckUpgrade"
        }
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
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
        case let .pickDestiny(drawings):
            return try TraceSubmission(
                kind: "PickDestinyAnswer",
                payload: PickDestinyAnswer(contents: drawings)
            )
        case let .campaignSpecific(contents):
            return try TraceSubmission(
                kind: "CampaignSpecificAnswer",
                payload: CampaignSpecificAnswer(contents: contents)
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
    let coverage: PlaythroughCoverageReport
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

private struct SkillTestPreparationLoopCounter: Sendable {
    private var activeKey: String?
    private var counts: [String: Int] = [:]

    mutating func count(for currentKey: String?) -> Int {
        updateActiveKey(currentKey)
        guard let currentKey else { return 0 }
        return counts[currentKey, default: 0]
    }

    mutating func recordAdvanced(for currentKey: String?) {
        updateActiveKey(currentKey)
        guard let currentKey else { return }
        counts[currentKey, default: 0] += 1
    }

    private mutating func updateActiveKey(_ currentKey: String?) {
        guard activeKey != currentKey else { return }
        if let activeKey {
            counts.removeValue(forKey: activeKey)
        }
        activeKey = currentKey
    }
}

private struct PlaythroughCoverageReport: Sendable, Equatable {
    let scenarioOutcomes: [String: String]
    let actAdvanceSelectionsByScenario: [String: Int]
    let agendaAdvanceSelectionsByScenario: [String: Int]
    let rawQuestionKindsSeen: [String]
    let presentationKindsSeen: [String]
    let choiceKindsSeen: [String]
    let selectionCounts: [String: Int]

    static let empty = PlaythroughCoverageReport(
        scenarioOutcomes: [:],
        actAdvanceSelectionsByScenario: [:],
        agendaAdvanceSelectionsByScenario: [:],
        rawQuestionKindsSeen: [],
        presentationKindsSeen: [],
        choiceKindsSeen: [],
        selectionCounts: [:]
    )

    var nonNoResolutionScenarioIDs: [String] {
        scenarioOutcomes.keys.sorted().filter { scenarioID in
            isResolutionOutcome(scenarioOutcomes[scenarioID] ?? "")
        }
    }

    var scenarioResolutionSummary: String {
        guard !scenarioOutcomes.isEmpty else { return "not observed" }
        return scenarioOutcomes.keys.sorted().map { scenarioID in
            "\(scenarioID)=\(compactResolutionText(scenarioOutcomes[scenarioID] ?? ""))"
        }.joined(separator: "; ")
    }

    var actAdvanceSummary: String {
        scenarioCountSummary(actAdvanceSelectionsByScenario)
    }

    var agendaAdvanceSummary: String {
        scenarioCountSummary(agendaAdvanceSelectionsByScenario)
    }

    var questionKindsSummary: String {
        listSummary(rawQuestionKindsSeen)
    }

    var presentationKindsSummary: String {
        listSummary(presentationKindsSeen)
    }

    var choiceKindsSummary: String {
        listSummary(choiceKindsSeen)
    }

    var selectionCountsSummary: String {
        countSummary(selectionCounts)
    }

    private func scenarioCountSummary(_ counts: [String: Int]) -> String {
        guard !counts.isEmpty else { return "none" }
        return counts.keys.sorted().map { "\($0)=\(counts[$0] ?? 0)" }
            .joined(separator: "; ")
    }
}

private struct PlaythroughCoverageAccumulator {
    private var rawQuestionKindsSeen: Set<String> = []
    private var presentationKindsSeen: Set<String> = []
    private var choiceKindsSeen: Set<String> = []
    private var selectionCounts: [String: Int] = [:]
    private var actAdvanceSelectionsByScenario: [String: Int] = [:]
    private var agendaAdvanceSelectionsByScenario: [String: Int] = [:]

    mutating func recordPrompt(_ prompt: BasicChoicePromptPresentation) {
        rawQuestionKindsSeen.insert(describeRawQuestionTag(prompt.identity.rawQuestion))
        if let questionKind = prompt.identity.questionPresentation?.questionKind.rawValue {
            presentationKindsSeen.insert(questionKind)
        }
        for choice in prompt.identity.questionPresentation?.choices ?? [] {
            choiceKindsSeen.insert(choice.kind.rawValue)
        }
    }

    mutating func recordSelection(scenario: String, answer: SelectedBotAnswer) {
        let key = answer.chosenChoiceKind ?? answer.answer.coverageKind
        selectionCounts[key, default: 0] += 1
        let advanceActKind = QuestionPresentation.ChoiceKind.advanceAct.rawValue
        let advanceAgendaKind = QuestionPresentation.ChoiceKind.advanceAgenda.rawValue
        if answer.chosenChoiceKind == advanceActKind {
            actAdvanceSelectionsByScenario[scenario, default: 0] += 1
        } else if answer.chosenChoiceKind == advanceAgendaKind {
            agendaAdvanceSelectionsByScenario[scenario, default: 0] += 1
        }
    }

    func report(scenarioOutcomes: [String: String]) -> PlaythroughCoverageReport {
        PlaythroughCoverageReport(
            scenarioOutcomes: scenarioOutcomes,
            actAdvanceSelectionsByScenario: actAdvanceSelectionsByScenario,
            agendaAdvanceSelectionsByScenario: agendaAdvanceSelectionsByScenario,
            rawQuestionKindsSeen: rawQuestionKindsSeen.sorted(),
            presentationKindsSeen: presentationKindsSeen.sorted(),
            choiceKindsSeen: choiceKindsSeen.sorted(),
            selectionCounts: selectionCounts
        )
    }
}

private func isResolutionOutcome(_ outcome: String) -> Bool {
    outcome.hasPrefix("resolution ") && outcome.contains("\"tag\":\"Resolution\"")
}

private func compactResolutionText(_ outcome: String) -> String {
    if outcome.contains("NoResolution") {
        return "NoResolution"
    }
    return outcome
        .replacingOccurrences(of: "resolution ", with: "")
        .replacingOccurrences(of: "|", with: "\\|")
}

private func listSummary(_ values: [String]) -> String {
    values.isEmpty ? "none" : values.joined(separator: ", ")
}

private func countSummary(_ counts: [String: Int]) -> String {
    guard !counts.isEmpty else { return "none" }
    return counts.keys.sorted().map { "\($0)=\(counts[$0] ?? 0)" }
        .joined(separator: "; ")
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

private struct TraceInvestigatorStatus: Encodable, Sendable {
    let investigatorID: String
    let damage: Int
    let horror: Int
    let clues: Int
    let resources: Int
    let health: Int
    let sanity: Int
    let remainingActions: Int
    let defeated: Bool
    let resigned: Bool
}

private struct TraceActProgress: Encodable, Sendable {
    let id: String
    let cardCode: String
    let sequence: String
    let flipped: Bool
    let advanceCostSummary: String?
    let clues: Int
}

private struct TraceAgendaProgress: Encodable, Sendable {
    let id: String
    let cardCode: String
    let sequence: String
    let doom: Int
    let doomThresholdSummary: String?
    let flipped: Bool
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
    let investigatorStatus: TraceInvestigatorStatus?
    let actProgress: [TraceActProgress]
    let agendaProgress: [TraceAgendaProgress]
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

private extension TraceInvestigatorStatus {
    init(_ investigator: BoardInvestigatorNode) {
        investigatorID = investigator.id.rawValue.rawValue
        damage = traceTokenCount("Damage", in: investigator.tokenCounts)
        horror = traceTokenCount("Horror", in: investigator.tokenCounts)
        clues = traceTokenCount("Clue", in: investigator.tokenCounts)
        resources = traceTokenCount("Resource", in: investigator.tokenCounts)
        health = investigator.health
        sanity = investigator.sanity
        remainingActions = investigator.remainingActions
        defeated = investigator.defeated
        resigned = investigator.resigned
    }
}

private extension TraceActProgress {
    init(_ act: BoardActNode) {
        id = act.id.rawValue.rawValue
        cardCode = act.cardCode.rawValue
        sequence = "\(act.sequence.step)\(act.sequence.side.rawValue)"
        flipped = act.flipped
        advanceCostSummary = act.advanceCostSummary
        clues = traceTokenCount("Clue", in: act.tokenCounts)
    }
}

private extension TraceAgendaProgress {
    init(_ agenda: BoardAgendaNode) {
        id = agenda.id.rawValue.rawValue
        cardCode = agenda.cardCode.rawValue
        sequence = "\(agenda.sequence.step)\(agenda.sequence.side.rawValue)"
        doom = agenda.doom
        doomThresholdSummary = agenda.doomThresholdSummary
        flipped = agenda.flipped
    }
}

private func traceTokenCount(_ token: String, in tokens: [BoardTokenSummary]) -> Int {
    tokens.first { $0.token == token }?.count ?? 0
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
        case .pickDestiny:
            answerKind = "PickDestinyAnswer"
            choiceIndex = nil
        case .campaignSpecific:
            answerKind = "CampaignSpecificAnswer"
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
        investigatorStatus = projection.investigators.first {
            $0.playerID == prompt.identity.ownerID
        }.map(TraceInvestigatorStatus.init)
        actProgress = projection.acts.map(TraceActProgress.init)
        agendaProgress = projection.agendas.map(TraceAgendaProgress.init)
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
    let coverage: PlaythroughCoverageReport
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
            "no eligible replacement investigator for \(investigatorID)"
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

    static let replacementSupport: [InvestigatorFixture] = [
        InvestigatorFixture(
            code: "02001", name: "Zoey Samaras", weakness: "02007",
            requiredCards: ["02006"], ordinaryCards: guardian0 + neutralCore,
            secondCopies: ["01017", "01020"]
        ),
        InvestigatorFixture(
            code: "02002", name: "Rex Murphy", weakness: "02009",
            requiredCards: ["02008"], ordinaryCards: seeker0 + neutralCore,
            secondCopies: ["01031", "01033"]
        ),
        InvestigatorFixture(
            code: "02003", name: "Jenny Barnes", weakness: "02011",
            requiredCards: ["02010"], ordinaryCards: rogue0 + neutralCore,
            secondCopies: ["01047", "01048"]
        ),
        InvestigatorFixture(
            code: "02004", name: "Jim Culver", weakness: "02013",
            requiredCards: ["02012"], ordinaryCards: mystic0 + neutralCore,
            secondCopies: ["01059", "01060"]
        ),
        InvestigatorFixture(
            code: "02005", name: "\"Ashcan\" Pete", weakness: "02015",
            requiredCards: ["02014"], ordinaryCards: survivor0 + neutralCore,
            secondCopies: ["01072", "01073"]
        ),
    ]

    static let replacementPool = core + replacementSupport

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

private func basicChoicePromptAdvanced(
    from identity: BasicChoicePromptIdentity,
    to current: BasicChoicePromptPresentation
) -> Bool {
    current.identity.promptKey != identity.promptKey
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

// swiftlint:disable:next function_body_length
private func preferredSelectableIndex(
    in prompt: BasicChoicePromptPresentation,
    projection: BoardProjection,
    selectableIndexes: [Int],
    repeatCount: Int,
    skillTestPreparationCount: Int,
    seed: UInt64 = 0,
    failedFightEnemyIDs: Set<String> = []
) -> Int {
    // The live harness strategy is deterministic and seedable: semantic v2 choices are
    // scored from server-published kinds/entities/abilities only, then equal-score ties
    // rotate by repeat count plus `ARKHAM_LIVE_BOT_SEED`. It never fabricates an answer;
    // the returned index is always one of the server-offered selectable source indices.
    if let startSkillTestIndex = forcedStartSkillTestIndex(
        in: prompt,
        selectableIndexes: selectableIndexes,
        skillTestPreparationCount: skillTestPreparationCount
    ) {
        return startSkillTestIndex
    }
    guard let presentation = prompt.identity.questionPresentation else {
        return selectableIndexes[seededOffset(
            repeatCount: repeatCount,
            seed: seed,
            count: selectableIndexes.count
        )]
    }
    if let pickSupplyIndex = preferredPickSupplyIndex(
        in: prompt,
        selectableIndexes: selectableIndexes
    ) {
        return pickSupplyIndex
    }
    let selectableChoices = presentation.choices.filter {
        $0.selectable && selectableIndexes.contains($0.sourceIndex)
    }
    guard !selectableChoices.isEmpty else {
        return selectableIndexes[seededOffset(
            repeatCount: repeatCount,
            seed: seed,
            count: selectableIndexes.count
        )]
    }
    let repeatedEndTurn = selectableChoices.first(where: { $0.kind == .endTurn })
    if repeatCount >= 5, let endTurn = repeatedEndTurn {
        return endTurn.sourceIndex
    }
    let context = BotStrategyContext(
        prompt: prompt,
        projection: projection,
        skillTestPreparationCount: skillTestPreparationCount,
        failedFightEnemyIDs: failedFightEnemyIDs
    )
    let objectiveAvailable = selectableChoices.contains { choice in
        context.isObjectiveProgress(choice)
    }
    let ranked = selectableChoices.map { choice in
        BotChoiceRank(
            sourceIndex: choice.sourceIndex,
            score: context.score(choice, objectiveAvailable: objectiveAvailable)
        )
    }
    let bestScore = ranked.map(\.score).max() ?? 0
    let best = ranked.filter { $0.score == bestScore }.map(\.sourceIndex).sorted()
    return best[seededOffset(repeatCount: repeatCount, seed: seed, count: best.count)]
}

private func forcedStartSkillTestIndex(
    in prompt: BasicChoicePromptPresentation,
    selectableIndexes: [Int],
    skillTestPreparationCount: Int
) -> Int? {
    guard skillTestPreparationCount >= 3 else { return nil }
    return prompt.choices.first(where: {
        if case .startSkillTest = $0.content {
            selectableIndexes.contains($0.index)
        } else {
            false
        }
    })?.index
}

private func preferredPickSupplyIndex(
    in prompt: BasicChoicePromptPresentation,
    selectableIndexes: [Int]
) -> Int? {
    guard prompt.identity.rawQuestion.objectValue?["tag"]?.stringValue == "PickSupplies",
          let rawChoices = prompt.identity.rawQuestion.objectValue?["choices"]?.arrayValue
    else { return nil }
    return selectableIndexes.sorted().first { index in
        rawChoices.indices.contains(index) && containsPickSupplyMessage(rawChoices[index])
    }
}

private func containsPickSupplyMessage(_ value: JSONValue) -> Bool {
    if value.objectValue?["tag"]?.stringValue == "PickSupply" {
        return true
    }
    if let object = value.objectValue {
        return object.values.contains(where: containsPickSupplyMessage)
    }
    if let array = value.arrayValue {
        return array.contains(where: containsPickSupplyMessage)
    }
    return false
}

private struct BotChoiceRank: Sendable, Equatable {
    let sourceIndex: Int
    let score: Int
}

private extension BoardSkillTestProjection {
    var failed: Bool? {
        guard case let .available(summary) = self else { return nil }
        if let verdict = summary.verdict {
            return !verdict.succeeded
        }
        if let result = summary.result {
            return !result.succeeded
        }
        return nil
    }
}

private func updatePendingFightOutcome(
    skillTest: BoardSkillTestProjection?,
    pendingFightEnemyID: inout String?,
    failedFightEnemyIDs: inout Set<String>
) {
    guard let foughtEnemyID = pendingFightEnemyID,
          let fightFailed = skillTest.flatMap(\.failed)
    else { return }
    if fightFailed {
        failedFightEnemyIDs.insert(foughtEnemyID)
    }
    pendingFightEnemyID = nil
}

// swiftlint:disable:next type_body_length
private struct BotStrategyContext {
    let prompt: BasicChoicePromptPresentation
    let projection: BoardProjection
    let skillTestPreparationCount: Int
    let failedFightEnemyIDs: Set<String>

    private var actingInvestigator: BoardInvestigatorNode? {
        projection.investigators.first { $0.playerID == prompt.identity.ownerID }
    }

    private var currentLocation: BoardLocationNode? {
        guard let locationID = actingInvestigator?.currentLocationID else { return nil }
        return projection.locations.first { $0.id == locationID }
    }

    func isObjectiveProgress(_ choice: QuestionPresentation.Choice) -> Bool {
        switch choice.kind {
        case .advanceAct, .advanceAgenda, .investigate, .fight, .evade, .move:
            true
        case .chooseTarget:
            choice.entity?.kind == .location
        case .useAbility, .effectActionButton:
            choice.ability?.type == .objective
                || choice.ability?.actions.contains(where: objectiveAction) == true
        default:
            false
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    func score(_ choice: QuestionPresentation.Choice, objectiveAvailable _: Bool) -> Int {
        var score = 0
        switch choice.kind {
        case .advanceAct:
            score = canPayActAdvanceCost ? 11000 : 10000
        case .advanceAgenda:
            score = 9800
        case .investigate:
            score = currentLocation?.clueCount ?? 0 > 0 ? 9400 : 6200
        case .fight:
            score = fightScore(choice)
        case .evade:
            score = evadeScore(choice)
        case .move:
            score = moveScore(choice)
        case .chooseTarget:
            score = chooseTargetScore(choice)
        case .useAbility, .effectActionButton:
            score = abilityScore(choice)
        case .assignDamage:
            score = survivabilityScore(choice, damage: 1, horror: 0)
        case .assignHorror:
            score = survivabilityScore(choice, damage: 0, horror: 1)
        case .skipTriggers:
            score = 5800
        case .applySkillTestResults, .startSkillTest:
            score = 7500
        case .drawEncounterCard:
            score = 3000
        case .endTurn:
            score = 2500
        case .gainResource, .drawCard:
            score = 4000
        case .auto, .localizedLabel, .wizardChoice:
            score = 3500
        case .engage:
            score = 5500
        case .resolveForcedAbility:
            score = 7000
        default:
            score = 1000
        }
        if isResign(choice) {
            score -= 9000
        }
        if choice.completesSelection == true {
            score -= 200
        }
        return score
    }

    private var engagedEnemyCount: Int {
        guard let investigatorID = actingInvestigator?.id else { return 0 }
        return projection.engagedEnemiesByInvestigatorID[investigatorID]?.count
            ?? actingInvestigator?.engagedEnemyCount ?? 0
    }

    private var investigatorClues: Int {
        tokenCount("Clue", in: actingInvestigator?.tokenCounts ?? [])
    }

    private var investigatorResources: Int {
        tokenCount("Resource", in: actingInvestigator?.tokenCounts ?? [])
    }

    private var canPayActAdvanceCost: Bool {
        projection.acts.contains { act in
            guard !act.flipped,
                  let cost = act.advanceCostSummary?.lowercased(),
                  cost.contains("clue")
            else { return false }
            return investigatorClues > 0
        }
    }

    private var promptOffersStartSkillTest: Bool {
        prompt.identity.questionPresentation?.choices.contains {
            $0.kind == .startSkillTest
        } == true
    }

    private func fightScore(_ choice: QuestionPresentation.Choice) -> Int {
        guard engagedEnemyCount > 0 else { return 3400 }
        if let enemyID = choice.entity?.id, failedFightEnemyIDs.contains(enemyID) {
            return 5000
        }
        return 9100
    }

    private func evadeScore(_ choice: QuestionPresentation.Choice) -> Int {
        guard engagedEnemyCount > 0 else { return 3300 }
        if let enemyID = choice.entity?.id, failedFightEnemyIDs.contains(enemyID) {
            return 9300
        }
        return 8800
    }

    private func abilityScore(_ choice: QuestionPresentation.Choice) -> Int {
        guard let ability = choice.ability else { return 4500 }
        if ability.type == .objective {
            return canPayActAdvanceCost ? 10600 : 9600
        }
        if ability.actions.contains(.investigate) {
            return currentLocation?.clueCount ?? 0 > 0 ? 9200 : 6000
        }
        if ability.actions.contains(.fight) {
            return fightScore(choice) - 100
        }
        if ability.actions.contains(.evade) {
            return evadeScore(choice) - 100
        }
        if ability.actions.contains(.move) {
            return moveScore(choice)
        }
        if ability.actions.contains(.resign) {
            return 1500
        }
        return 4500
    }

    private func chooseTargetScore(_ choice: QuestionPresentation.Choice) -> Int {
        if choice.entity?.kind == .card {
            if promptOffersStartSkillTest, skillTestPreparationCount == 0 {
                return 7900
            }
            if actingInvestigator?.remainingActions ?? 0 >= 2, investigatorResources > 0 {
                return 8300
            }
            return 3900
        }
        guard choice.entity?.kind == .location else { return 3000 }
        return moveScore(choice)
    }

    private func moveScore(_ choice: QuestionPresentation.Choice) -> Int {
        guard let targetLocation = location(for: choice.entity) else { return 6000 }
        if targetLocation.clueCount > 0 {
            return 9000
        }
        if !targetLocation.revealed {
            return 8800
        }
        guard let current = currentLocation else { return 6000 }
        let currentDistance = distanceFromClosestPotentialClueLocation(to: current.id)
        let targetDistance = distanceFromClosestPotentialClueLocation(to: targetLocation.id)
        let targetIsCloserToClues = targetDistance.map {
            currentDistance == nil || $0 < (currentDistance ?? .max)
        } ?? false
        if targetIsCloserToClues {
            return 8100
        }
        return 6000
    }

    private func survivabilityScore(
        _ choice: QuestionPresentation.Choice, damage: Int, horror: Int
    ) -> Int {
        let actingWouldBeDefeated = wouldDefeatActingInvestigator(damage: damage, horror: horror)
        if choice.entity?.kind == .asset {
            return actingWouldBeDefeated ? 9000 : 7200
        }
        guard let investigator = investigator(for: choice.entity ?? choice.actorEntity) else {
            return 6800
        }
        let remainingHealth = remainingHealth(for: investigator)
        let remainingSanity = remainingSanity(for: investigator)
        if damage > 0, remainingHealth - damage <= 0 {
            return 1200
        }
        if horror > 0, remainingSanity - horror <= 0 {
            return 1200
        }
        return 7600 + max(0, remainingHealth - damage) + max(0, remainingSanity - horror)
    }

    private func wouldDefeatActingInvestigator(damage: Int, horror: Int) -> Bool {
        guard let investigator = actingInvestigator else { return false }
        return (damage > 0 && remainingHealth(for: investigator) - damage <= 0)
            || (horror > 0 && remainingSanity(for: investigator) - horror <= 0)
    }

    private func remainingHealth(for investigator: BoardInvestigatorNode) -> Int {
        investigator.health
            - investigator.physicalTrauma
            - investigator.assignedHealthDamage
            - tokenCount("Damage", in: investigator.tokenCounts)
    }

    private func remainingSanity(for investigator: BoardInvestigatorNode) -> Int {
        investigator.sanity
            - investigator.mentalTrauma
            - investigator.assignedSanityDamage
            - tokenCount("Horror", in: investigator.tokenCounts)
    }

    private func tokenCount(_ token: String, in tokens: [BoardTokenSummary]) -> Int {
        tokens.first { $0.token == token }?.count ?? 0
    }

    private func isResign(_ choice: QuestionPresentation.Choice) -> Bool {
        choice.ability?.actions.contains(.resign) == true
    }

    private func objectiveAction(_ action: QuestionPresentation.Action) -> Bool {
        switch action {
        case .investigate, .move, .fight, .evade, .explore, .parley:
            true
        default:
            false
        }
    }

    private func location(for entity: QuestionPresentation.Entity?) -> BoardLocationNode? {
        guard entity?.kind == .location, let id = entity?.id.lowercased() else { return nil }
        return projection.locations.first { $0.id.codingKey.stringValue == id }
    }

    private func investigator(for entity: QuestionPresentation.Entity?) -> BoardInvestigatorNode? {
        guard let entity else { return actingInvestigator }
        guard entity.kind == .investigator else { return nil }
        let id = entity.id.lowercased()
        return projection.investigators.first { $0.id.rawValue.rawValue == id }
    }

    private func distanceFromClosestPotentialClueLocation(to destination: LocationID) -> Int? {
        let clueLocationIDs = Set(projection.locations.filter {
            $0.clueCount > 0 || !$0.revealed
        }.map(\.id))
        guard !clueLocationIDs.isEmpty else { return nil }
        if clueLocationIDs.contains(destination) {
            return 0
        }
        var visited: Set<LocationID> = [destination]
        var frontier: [(LocationID, Int)] = [(destination, 0)]
        while !frontier.isEmpty {
            let (locationID, distance) = frontier.removeFirst()
            guard let location = projection.locations.first(where: { $0.id == locationID })
            else { continue }
            for neighbor in location.connectedLocationIDs where !visited.contains(neighbor) {
                if clueLocationIDs.contains(neighbor) {
                    return distance + 1
                }
                visited.insert(neighbor)
                frontier.append((neighbor, distance + 1))
            }
        }
        return nil
    }
}

private extension QuestionPresentation.Choice {
    var actorEntity: QuestionPresentation.Entity? {
        actorID.map { QuestionPresentation.Entity(kind: .investigator, id: $0) }
    }
}

private func seededOffset(repeatCount: Int, seed: UInt64, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return (repeatCount + Int(seed % UInt64(count))) % count
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
