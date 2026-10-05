// swiftlint:disable file_length
@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Env-gated live-server smoke coverage for task-1.2.12. It is intentionally absent
/// from normal CI unless `ARKHAM_LIVE_SERVER_URL` is set; when enabled it drives the
/// production `AppModel` authentication, lifecycle, REST snapshot and WebSocket answer
/// paths against a real fork server.
private let notzScenarioOrder = ["01104", "01120", "01142"]

private func liveServerURLForPlaythrough() -> String? {
    guard let rawURL = ProcessInfo.processInfo.environment["ARKHAM_LIVE_SERVER_URL"],
          !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return rawURL
}

@MainActor
@Suite("Live Night of the Zealot playthrough")
struct LiveNightOfTheZealotPlaythroughTests {
    private static let resultPath = "/tmp/arkham-logs/playthrough-results.md"

    private static func tracePath(for investigator: InvestigatorFixture) -> String {
        "/tmp/arkham-logs/playthrough-trace-\(investigator.traceSlug).jsonl"
    }

    @Test(
        "Env-gated solo NotZ playthroughs for every core investigator",
        .enabled(if: liveServerURLForPlaythrough() != nil)
    )
    func coreInvestigatorCampaigns() async throws {
        let rawURL = try #require(liveServerURLForPlaythrough())

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

            let trace = PlaythroughTraceRecorder(path: Self.tracePath(for: investigator))
            try trace.reset()
            let bot = LivePlaythroughBot(
                model: model,
                lifecycle: lifecycle,
                profile: signedInProfile,
                token: token,
                gameID: gameID,
                investigator: investigator,
                deck: deck,
                trace: trace,
                diagnosticBypassUnsupported: Self.diagnosticBypassUnsupported
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
    let deck: Deck
    let trace: PlaythroughTraceRecorder
    let diagnosticBypassUnsupported: Bool

    // swiftlint:disable:next function_body_length
    func driveUntilCampaignOver() async throws -> BotOutcome {
        var repeatedQuestionShapes: [String: Int] = [:]
        let startedAt = Date()
        let timeout = ProcessInfo.processInfo.environment["ARKHAM_LIVE_PLAYTHROUGH_TIMEOUT"]
            .flatMap(TimeInterval.init) ?? 900
        try trace.append(.runStarted(investigator: investigator, gameID: gameID))
        while Date().timeIntervalSince(startedAt) < timeout {
            let envelope = try await lifecycle.getGame(gameID, on: profile, token: token)
            let scenarioOutcomes = scenarioOutcomes(from: envelope.game)
            if envelope.game.gameState == .over {
                try trace.append(.runFinished(
                    investigator: investigator,
                    gameID: gameID,
                    reachedDevourerResolution: scenarioOutcomes["01142"]?
                        .hasPrefix("resolution") == true,
                    scenarioOutcomes: scenarioOutcomes
                ))
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
            let repeatKey = coverageRepeatKey(scenario: scenario, prompt: prompt)
            let repeatCount = repeatedQuestionShapes[repeatKey, default: 0]
            let cannotRender = !prompt.isRenderableQuestion
                && !isInitialChooseDeckPrompt(prompt)
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
                    reachedDevourerResolution: false,
                    scenarioOutcomes: scenarioOutcomes,
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
                    reachedDevourerResolution: false,
                    scenarioOutcomes: scenarioOutcomes,
                    promptFailure: failure
                )
            }

            let selectedAnswer: SelectedBotAnswer
            do {
                selectedAnswer = try selectAnswer(
                    prompt: prompt,
                    projection: projection,
                    repeatCount: repeatCount
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
                    reachedDevourerResolution: false,
                    scenarioOutcomes: scenarioOutcomes,
                    promptFailure: failure
                )
            }

            let submission = try selectedAnswer.answer.traceSubmission(prompt: prompt)
            do {
                let submitOutcome = try await submit(selectedAnswer.answer, prompt: prompt)
                let advanced = try await waitForPromptAdvance(from: prompt.identity)
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
                        serverFeedback: feedback
                    ))
                    return BotOutcome(
                        reachedDevourerResolution: false,
                        scenarioOutcomes: scenarioOutcomes,
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
                    reachedDevourerResolution: false,
                    scenarioOutcomes: scenarioOutcomes,
                    promptFailure: failure
                )
            }
        }
        let envelope = try await lifecycle.getGame(gameID, on: profile, token: token)
        let prompt = model.basicChoicePresentation(for: gameID)
        let failure = PromptFailure(
            scenario: currentScenarioCode(
                projection: model.liveGameState(for: gameID).lastKnownProjection,
                snapshot: envelope.game
            ),
            investigator: investigator,
            questionVersion: prompt?.questionVersion ?? -1,
            rawQuestionTag: prompt.map {
                describeRawQuestionTag($0.identity.rawQuestion)
            } ?? "none",
            reason: "playthrough timed out before campaign end"
        )
        try trace.append(.runTimedOut(
            investigator: investigator,
            gameID: gameID,
            failure: failure,
            scenarioOutcomes: scenarioOutcomes(from: envelope.game)
        ))
        return BotOutcome(
            reachedDevourerResolution: false,
            scenarioOutcomes: scenarioOutcomes(from: envelope.game),
            promptFailure: failure
        )
    }

    private func waitForProjection() async throws -> BoardProjection? {
        try await waitForValue(timeout: 20, description: "live projection") {
            model.liveGameState(for: gameID).lastKnownProjection
        }
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
        repeatCount: Int
    ) throws -> SelectedBotAnswer {
        if isInitialChooseDeckPrompt(prompt) {
            return SelectedBotAnswer(
                answer: .savedDeck(deck), note: "starter deck", chosenChoiceKind: nil
            )
        }
        if prompt.isChooseUpgradeDeckPrompt {
            return SelectedBotAnswer(
                answer: .skipDeckUpgrade(investigatorID: investigator.code),
                note: "continue without upgrading",
                chosenChoiceKind: nil
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
        let selectedIndex = selectableIndexes[repeatCount % selectableIndexes.count]
        let chosenChoiceKind = prompt.identity.questionPresentation?.choices.first {
            $0.sourceIndex == selectedIndex
        }?.kind.rawValue
        return SelectedBotAnswer(
            answer: .choice(selectedIndex),
            note: "selectable choice \(selectedIndex)",
            chosenChoiceKind: chosenChoiceKind
        )
    }

    private func canDiagnosticBypassUnsupported(_ prompt: BasicChoicePromptPresentation) -> Bool {
        guard diagnosticBypassUnsupported, prompt.readOnlyReason == nil else { return false }
        return prompt.identity.questionPresentation?.choices
            .contains { $0.selectable } == true
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
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

    private func waitForPromptAdvance(
        from identity: BasicChoicePromptIdentity
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            guard let current = model.basicChoicePresentation(for: gameID) else { return true }
            if current.identity.promptKey != identity.promptKey {
                return true
            }
            let state = model.liveGameState(for: gameID)
            if state.lastKnownProjection?.counters.gameStateSummary == "Completed" {
                return true
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
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

private enum BotAnswer: Sendable {
    case choice(Int)
    case amounts([String: Int])
    case paymentAmounts([String: Int])
    case exchangeAmount(Int)
    case continueCampaign(JSONValue)
    case savedDeck(Deck)
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
        case let .skipDeckUpgrade(investigatorID):
            return TraceSubmission(
                kind: "SkipDeckUpgrade",
                encodedPayload: .object(["investigatorId": .string(investigatorID)])
            )
        }
    }
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
    let title: String
    let contentKind: String
    let isSupported: Bool
    let isDisplayed: Bool
    let isActionable: Bool
    let semanticKind: String?
    let semanticSelectable: Bool?
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
        reachedDevourerResolution: Bool,
        scenarioOutcomes: [String: String]
    ) -> PlaythroughTraceRecord {
        base(
            event: "runFinished",
            investigator: investigator,
            gameID: gameID,
            outcome: TraceOutcome(
                kind: reachedDevourerResolution ? "passed" : "failed",
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
        return TraceAppChoice(
            index: choice.index,
            title: choice.title,
            contentKind: choiceContentKind(choice.content),
            isSupported: choice.isSupported,
            isDisplayed: displayed.contains(choice.index),
            isActionable: prompt.isChoiceActionable(choice, in: projection),
            semanticKind: descriptor?.kind.rawValue,
            semanticSelectable: descriptor?.selectable,
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
