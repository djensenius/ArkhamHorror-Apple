// swiftlint:disable file_length
@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Env-gated live-server smoke coverage for task-1.2.12. It is intentionally absent
/// from normal CI unless `ARKHAM_LIVE_SERVER_URL` is set; when enabled it drives the
/// production `AppModel` authentication, lifecycle, REST snapshot and WebSocket answer
/// paths against a real fork server.
private let notzScenarioOrder = ["01104", "01120", "01142"]

@MainActor
@Suite("Live Night of the Zealot playthrough")
struct LiveNightOfTheZealotPlaythroughTests {
    private static let resultPath = "/tmp/arkham-logs/playthrough-results.md"

    @Test("Env-gated solo NotZ playthroughs for every core investigator")
    func coreInvestigatorCampaigns() async throws {
        guard let rawURL = ProcessInfo.processInfo.environment["ARKHAM_LIVE_SERVER_URL"],
              !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        let profile = try ServerProfile.custom(
            displayName: "Task 1.2.12 live server",
            rawURL: rawURL
        )
        var results: [PlaythroughResult] = []
        try writeResults(
            results,
            note: "Started live playthroughs against \(profile.endpointSummary)."
        )

        for investigator in InvestigatorFixture.core {
            let result = await runInvestigator(investigator, on: profile)
            results.append(result)
            try writeResults(results, note: "Recorded \(investigator.name).")
        }

        try writeResults(results, note: "Finished live playthrough run.")
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
        on profile: ServerProfile
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
            let gameID = try await model.createGame(
                CreateGameRequest(
                    deckIds: [deck.id],
                    playerCount: 1,
                    campaignOrScenario: CampaignOrScenario(
                        campaignId: "01", scenarioId: nil
                    ),
                    difficulty: .easy,
                    campaignName: "Task 1.2.12 — \(investigator.name)",
                    multiplayerVariant: .solo,
                    includeTarotReadings: false,
                    options: [],
                    strictAsIfAt: .absent,
                    asIfRuling: .absent,
                    ultimatumsAndBoons: .absent,
                    achievementsEnabled: .value(false)
                )
            )

            let subscription = model.subscribeToLiveGame(gameID)
            defer { model.unsubscribeFromLiveGame(subscription) }

            let bot = LivePlaythroughBot(
                model: model,
                lifecycle: lifecycle,
                profile: signedInProfile,
                token: token,
                gameID: gameID,
                investigator: investigator,
                deckID: deck.id
            )
            let outcome = try await bot.driveUntilCampaignOver()
            scenarioOutcomes = outcome.scenarioOutcomes
            promptFailure = outcome.promptFailure
            if outcome.reachedDevourerResolution {
                return PlaythroughResult(
                    investigator: investigator,
                    status: .passed,
                    scenarioOutcomes: scenarioOutcomes,
                    promptFailure: nil,
                    finalGameID: gameID.rawValue.uuidString.lowercased()
                )
            }
            let reason = promptFailure?.description
                ?? "campaign stopped without IsOver and a 01142 resolution"
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
            email: "task-1-2-12-\(investigator.code)-\(suffix)@example.test",
            username: "task-1-2-12-\(investigator.code)-\(suffix.prefix(8))",
            password: "task-1-2-12-password"
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

    private func waitForLocaleCatalogIfAdvertised(_ model: AppModel) async throws {
        guard model.localeCatalogRequest != nil || model.isLocaleCatalogLoading else { return }
        try await waitUntil(timeout: 30, description: "locale catalog loads or fails") {
            !model.isLocaleCatalogLoading
        }
    }

    private func writeResults(_ results: [PlaythroughResult], note: String) throws {
        try FileManager.default.createDirectory(
            atPath: "/tmp/arkham-logs", withIntermediateDirectories: true
        )
        var lines: [String] = [
            "# Night of the Zealot live playthrough results",
            "",
            "\(note)",
            "",
            "| Investigator | Status | 01104 | 01120 | 01142 | Failing prompt | Game |",
            "| --- | --- | --- | --- | --- | --- | --- |",
        ]
        for result in results {
            let failure = result.promptFailure?.markdownSummary ?? "—"
            let game = result.finalGameID ?? "—"
            lines.append(
                "| \(result.investigator.name) (\(result.investigator.code))"
                    + " | \(result.status.tableText)"
                    + " | \(result.scenarioOutcomes["01104"] ?? "not observed")"
                    + " | \(result.scenarioOutcomes["01120"] ?? "not observed")"
                    + " | \(result.scenarioOutcomes["01142"] ?? "not observed")"
                    + " | \(failure) | \(game) |"
            )
        }
        lines.append("")
        lines.append("Generated: \(Date())")
        try lines.joined(separator: "\n").write(
            toFile: Self.resultPath, atomically: true, encoding: .utf8
        )
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
    let deckID: DeckID

    // swiftlint:disable:next function_body_length
    func driveUntilCampaignOver() async throws -> BotOutcome {
        var answeredPromptKeys = Set<String>()
        let startedAt = Date()
        let timeout = ProcessInfo.processInfo.environment["ARKHAM_LIVE_PLAYTHROUGH_TIMEOUT"]
            .flatMap(TimeInterval.init) ?? 900
        while Date().timeIntervalSince(startedAt) < timeout {
            let envelope = try await lifecycle.getGame(gameID, on: profile, token: token)
            let scenarioOutcomes = scenarioOutcomes(from: envelope.game)
            if envelope.game.gameState == .over {
                return BotOutcome(
                    reachedDevourerResolution: scenarioOutcomes["01142"]?
                        .hasPrefix("resolution") == true,
                    scenarioOutcomes: scenarioOutcomes,
                    promptFailure: nil
                )
            }

            guard let projection = try await waitForProjection() else {
                continue
            }
            guard let prompt = model.basicChoicePresentation(for: gameID) else {
                try await Task.sleep(for: .milliseconds(200))
                continue
            }
            let scenario = currentScenarioCode(projection: projection, snapshot: envelope.game)
            let promptKey = prompt.identity.diagnosticKey
            if answeredPromptKeys.contains(promptKey) {
                return BotOutcome(
                    reachedDevourerResolution: false,
                    scenarioOutcomes: scenarioOutcomes,
                    promptFailure: PromptFailure(
                        scenario: scenario,
                        investigator: investigator,
                        questionVersion: prompt.questionVersion,
                        rawQuestionTag: rawQuestionTag(prompt.identity.rawQuestion),
                        reason: "same prompt remained after the bot answered it"
                    )
                )
            }
            guard prompt.isRenderableQuestion || isInitialChooseDeckPrompt(prompt) else {
                return BotOutcome(
                    reachedDevourerResolution: false,
                    scenarioOutcomes: scenarioOutcomes,
                    promptFailure: PromptFailure(
                        scenario: scenario,
                        investigator: investigator,
                        questionVersion: prompt.questionVersion,
                        rawQuestionTag: rawQuestionTag(prompt.identity.rawQuestion),
                        reason: "prompt is not renderable by this app version"
                    )
                )
            }
            guard prompt.canSubmit || prompt.isChooseUpgradeDeckPrompt
                || isInitialChooseDeckPrompt(prompt)
            else {
                return BotOutcome(
                    reachedDevourerResolution: false,
                    scenarioOutcomes: scenarioOutcomes,
                    promptFailure: PromptFailure(
                        scenario: scenario,
                        investigator: investigator,
                        questionVersion: prompt.questionVersion,
                        rawQuestionTag: rawQuestionTag(prompt.identity.rawQuestion),
                        reason: prompt.statusMessage ?? "prompt is not answerable"
                    )
                )
            }

            let answer: BotAnswer
            do {
                answer = try selectAnswer(prompt: prompt, projection: projection)
            } catch let error as PlaythroughError {
                return BotOutcome(
                    reachedDevourerResolution: false,
                    scenarioOutcomes: scenarioOutcomes,
                    promptFailure: PromptFailure(
                        scenario: scenario,
                        investigator: investigator,
                        questionVersion: prompt.questionVersion,
                        rawQuestionTag: rawQuestionTag(prompt.identity.rawQuestion),
                        reason: error.description
                    )
                )
            }
            answeredPromptKeys.insert(promptKey)
            try await submit(answer, prompt: prompt)
            try await waitForPromptAdvance(from: prompt.identity)
        }
        let envelope = try await lifecycle.getGame(gameID, on: profile, token: token)
        return BotOutcome(
            reachedDevourerResolution: false,
            scenarioOutcomes: scenarioOutcomes(from: envelope.game),
            promptFailure: PromptFailure(
                scenario: currentScenarioCode(
                    projection: model.liveGameState(for: gameID).lastKnownProjection,
                    snapshot: envelope.game
                ),
                investigator: investigator,
                questionVersion: model.basicChoicePresentation(for: gameID)?.questionVersion ?? -1,
                rawQuestionTag: model.basicChoicePresentation(for: gameID).map {
                    rawQuestionTag($0.identity.rawQuestion)
                } ?? "none",
                reason: "playthrough timed out before campaign end"
            )
        )
    }

    private func waitForProjection() async throws -> BoardProjection? {
        try await waitForValue(timeout: 20, description: "live projection") {
            model.liveGameState(for: gameID).lastKnownProjection
        }
    }

    private func selectAnswer(
        prompt: BasicChoicePromptPresentation,
        projection: BoardProjection
    ) throws -> BotAnswer {
        if isInitialChooseDeckPrompt(prompt) {
            return .savedDeck(deckID)
        }
        if prompt.isChooseUpgradeDeckPrompt {
            return .skipDeckUpgrade(investigatorID: investigator.code)
        }
        if let continuation = projection.campaignContinuation, isContinueCampaignPrompt(prompt) {
            return .continueCampaign(continuation.nextStep)
        }
        if let amountPrompt = prompt.amountPrompt(in: projection) {
            return switch amountPrompt.kind {
            case .amounts: .amounts(minimumAmounts(for: amountPrompt))
            case .payment: .paymentAmounts(minimumAmounts(for: amountPrompt))
            }
        }
        if prompt.exchangePrompt(in: projection) != nil {
            return .exchangeAmount(0)
        }
        guard let choice = prompt.displayOrderedChoices().first(where: {
            prompt.isChoiceActionable($0, in: projection)
        }) else {
            throw PlaythroughError.noSelectableChoice(
                version: prompt.questionVersion,
                tag: rawQuestionTag(prompt.identity.rawQuestion)
            )
        }
        return .choice(choice.index)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func submit(_ answer: BotAnswer, prompt: BasicChoicePromptPresentation) async throws {
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
        case let .savedDeck(deckID):
            guard let connection = model.liveGameConnections[gameID]?.connection else {
                throw PlaythroughError.submissionFailed("deck answer socket was not connected")
            }
            let bytes = try ContractJSON.encode(
                DeckAnswer(deckId: deckID, playerId: prompt.identity.ownerID)
            )
            try await connection.send(bytes)
            return
        case let .skipDeckUpgrade(investigatorID):
            let deckResult = await model.continueCampaignWithoutUpgrading(
                investigatorId: investigatorID,
                in: gameID,
                promptIdentity: prompt.identity
            )
            switch deckResult {
            case .submitted:
                return
            case let .failed(message):
                throw PlaythroughError.submissionFailed(message)
            }
        }
        switch result {
        case .sentAwaitingSnapshot:
            return
        case .alreadyPending:
            throw PlaythroughError.submissionFailed("answer already pending")
        case .readOnly:
            throw PlaythroughError.submissionFailed("prompt became read-only")
        case .retryableFailure:
            throw PlaythroughError.submissionFailed("retryable answer failure")
        case .staleQuestion:
            throw PlaythroughError.submissionFailed("stale question")
        case .unsupportedChoice:
            throw PlaythroughError.submissionFailed("unsupported choice")
        }
    }

    private func waitForPromptAdvance(from identity: BasicChoicePromptIdentity) async throws {
        try await waitUntil(timeout: 30, description: "prompt advances") {
            guard let current = model.basicChoicePresentation(for: gameID) else { return true }
            if current.identity.promptKey != identity.promptKey {
                return true
            }
            let state = model.liveGameState(for: gameID)
            if state.lastKnownProjection?.counters.gameStateSummary == "Completed" {
                return true
            }
            return false
        }
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

    private func scenarioOutcomes(from snapshot: PublicGameSnapshot) -> [String: String] {
        let campaign: JSONValue? = switch snapshot.mode {
        case let .campaignOnly(value), let .campaignAndScenario(value, _): value
        case .scenarioOnly: nil
        }
        let resolutions = campaign?.objectValue?["resolutions"]?.objectValue ?? [:]
        var outcomes: [String: String] = [:]
        for code in notzScenarioOrder {
            if let resolution = resolutions[code] ?? resolutions["c\(code)"] {
                outcomes[code] = "resolution \(jsonString(resolution))"
            } else {
                outcomes[code] = "not recorded"
            }
        }
        return outcomes
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

private enum BotAnswer {
    case choice(Int)
    case amounts([String: Int])
    case paymentAmounts([String: Int])
    case exchangeAmount(Int)
    case continueCampaign(JSONValue)
    case savedDeck(DeckID)
    case skipDeckUpgrade(investigatorID: String)
}

private struct BotOutcome {
    let reachedDevourerResolution: Bool
    let scenarioOutcomes: [String: String]
    let promptFailure: PromptFailure?
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
    case submissionFailed(String)
    case timedOut(String)

    var description: String {
        switch self {
        case let .notSignedOut(state): "expected signedOut after launch, got \(state)"
        case let .notSignedIn(state): "expected signedIn, got \(state)"
        case .registrationDidNotStart: "registration did not start"
        case let .noSelectableChoice(version, tag): "no selectable choice at q\(version) / \(tag)"
        case let .submissionFailed(reason): "submission failed: \(reason)"
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

    var createDeckRequest: CreateDeckRequest {
        guard let investigatorCode = try? InvestigatorCode(code) else {
            fatalError("Core investigator code fixture must be non-empty")
        }
        return CreateDeckRequest(
            deckId: "task-1.2.12-\(code)-\(UUID().uuidString.lowercased())",
            deckName: "\(name) task-1.2.12 starter",
            deckUrl: nil,
            deckList: DeckListInput(
                slots: CardQuantityMapInput(deckSlots),
                sideSlots: .valid(CardQuantityMapInput([:])),
                investigatorCode: investigatorCode,
                investigatorName: name,
                meta: nil,
                tabooId: nil,
                url: nil,
                id: .string("task-1.2.12-\(code)"),
                name: "\(name) task-1.2.12 starter"
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

private func currentScenarioCode(
    projection: BoardProjection?,
    snapshot: PublicGameSnapshot
) -> String {
    if let reference = projection?.scenario?.reference, notzScenarioOrder.contains(reference) {
        return reference
    }
    switch snapshot.mode {
    case let .scenarioOnly(scenario), let .campaignAndScenario(_, scenario):
        return scenario.id.rawValue
    case let .campaignOnly(campaign):
        return campaign.objectValue?["step"]?.objectValue?["contents"]?.stringValue
            ?? "campaign"
    }
}

private func rawQuestionTag(_ value: JSONValue) -> String {
    guard let object = value.objectValue else { return value.kindDescription }
    if let tag = object["tag"]?.stringValue {
        return tag
    }
    return value.kindDescription
}

private func jsonString(_ value: JSONValue) -> String {
    guard let data = try? ContractJSON.encode(value),
          let string = String(data: data, encoding: .utf8)
    else { return value.kindDescription }
    return string
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
) async throws -> T? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let value = producer() {
            return value
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw PlaythroughError.timedOut(description)
}
