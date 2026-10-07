// swiftlint:disable file_length
@testable import ArkhamHorrorShared
import Foundation
import Testing

private enum NightOfTheZealotCoverageEnvironmentKey {
    static let recordingsDirectory = "ARKHAM_NOTZ_COVERAGE_DIR"
    static let multiplayerRecordingsDirectory = "ARKHAM_NOTZ_MP_COVERAGE_DIR"
}

private struct NightOfTheZealotPreferredLanguages: PreferredLanguagesProviding {
    let preferredLanguages = ["en"]
}

private func nightOfTheZealotCoverageDirectoryURL() -> URL? {
    directoryURL(environmentKey: NightOfTheZealotCoverageEnvironmentKey.recordingsDirectory)
}

private func nightOfTheZealotMultiplayerCoverageDirectoryURL() -> URL? {
    directoryURL(
        environmentKey: NightOfTheZealotCoverageEnvironmentKey.multiplayerRecordingsDirectory
    )
}

private func directoryURL(environmentKey: String) -> URL? {
    guard let rawDirectory = ProcessInfo.processInfo.environment[environmentKey],
          !rawDirectory.isEmpty
    else { return nil }
    return URL(fileURLWithPath: rawDirectory, isDirectory: true)
}

@MainActor
@Suite("Night of the Zealot coverage replay")
// swiftlint:disable:next type_body_length
struct NightOfTheZealotCoverageReplayTests {
    @Test(
        "Replay coverage JSONL prompts through AppModel",
        .enabled(if: nightOfTheZealotCoverageDirectoryURL() != nil)
    )
    func replayCoverageJSONLPrompts() async throws {
        let directory = try #require(nightOfTheZealotCoverageDirectoryURL())
        try await run(recordings: CoverageRecordingLoader.load(directory: directory))
    }

    @Test(
        "Replay multiplayer coverage JSONL prompts through AppModel",
        .enabled(if: nightOfTheZealotMultiplayerCoverageDirectoryURL() != nil)
    )
    func replayMultiplayerCoverageJSONLPrompts() async throws {
        let directory = try #require(nightOfTheZealotMultiplayerCoverageDirectoryURL())
        try await runMultiplayer(recordings: CoverageRecordingLoader.load(directory: directory))
    }

    @Test("Replay smoke JSONL fixture through the coverage harness")
    func replaySmokeJSONLFixture() async throws {
        try await run(recordings: CoverageRecordingLoader.load(file: smokeFixtureURL()))
    }

    @Test("Replay multiplayer smoke JSONL fixture through the coverage harness")
    func replayMultiplayerSmokeJSONLFixture() async throws {
        let recordings = try CoverageRecordingLoader.load(
            directory: multiplayerSmokeFixtureDirectoryURL()
        )
        try await runMultiplayer(recordings: recordings)
    }

    @Test("Parameterized amount row labels catalog the bare choice key")
    func parameterizedAmountRowLabelsCatalogBareChoiceKey() {
        var keys = Set<String>()
        collectLocalizationKeys(
            from: .object([
                "amountChoices": .array([
                    .object(["label": .string("$damage count=i:1")]),
                ]),
            ]),
            into: &keys
        )

        #expect(keys.contains("choice.damage"))
        #expect(!keys.contains("choice.damage count=i:1"))
    }

    @Test("Multiplayer reconnect restores participant prompt and fences in-flight answer")
    // swiftlint:disable:next function_body_length
    func multiplayerReconnectRestoresParticipantPromptAndFencesInFlightAnswer() async throws {
        let recording = try smokeRecording(named: "3p-smoke.jsonl")
        let runDefinition = try MultiplayerRunDefinition(fileName: recording.fileName)
        let catalogDocuments = try makeSyntheticCatalog(for: [recording])
        let replay = try await CoverageReplaySession.start(
            first: recording,
            baseEnvelopeData: fixtureData(named: "get-game"),
            catalogDocuments: catalogDocuments,
            deck: sampleDeck(),
            runDefinition: runDefinition
        )
        let ownerID = try recording.record.recordedPlayerID()
        replay.model.liveGameParticipantIdentities[replay.gameID] = .participant(ownerID)
        let prompt = try #require(replay.model.basicChoicePresentation(for: replay.gameID))
        #expect(prompt.ownerID == ownerID)
        #expect(prompt.questionVersion == recording.record.questionVersion)
        #expect(prompt.readOnlyReason == nil)

        let submission = try RecordedCoverageSubmission(answer: recording.record.chosenAnswer)
        guard case let .singleChoice(choiceIndex) = submission else {
            throw CoverageReplayPromptFailure(
                record: recording,
                reason: "smoke reconnect test expected a single-choice answer"
            )
        }
        let expectedAnswer = try ContractJSON.encode(recording.record.chosenAnswer)
        await replay.connection.setSendGated(true)
        let firstSend = Task {
            await submit(submission, prompt: prompt, model: replay.model)
        }
        await replay.connection.waitUntilSendPending(1)
        #expect(replay.model.basicChoicePresentation(for: replay.gameID)?.actionPhase == .sending)
        #expect(
            await submit(submission, prompt: prompt, model: replay.model) == .alreadyPending
        )

        for seat in runDefinition.seats where seat.playerID != recording.record.playerID {
            let seatPlayerID = try seat.playerIDValue()
            replay.model.liveGameParticipantIdentities[replay.gameID] = .participant(
                seatPlayerID
            )
            #expect(replay.model.basicChoicePresentation(for: replay.gameID) == nil)
            #expect(
                await submit(submission, prompt: prompt, model: replay.model) == .staleQuestion
            )
        }
        replay.model.liveGameParticipantIdentities[replay.gameID] = .spectator
        #expect(replay.model.basicChoicePresentation(for: replay.gameID) == nil)
        #expect(
            await submit(submission, prompt: prompt, model: replay.model) == .staleQuestion
        )

        replay.model.liveGameParticipantIdentities[replay.gameID] = .participant(ownerID)
        await replay.connection.resumeOldestSend(with: .failure(GameSocketTransportError()))
        #expect(await firstSend.value == .retryableFailure)
        #expect(replay.model.basicChoicePresentation(for: replay.gameID)?.actionPhase
            == .retryable(.transportFailure))

        await replay.service.setGetGameGated(true)
        let replacement = FakeGameSocketConnection()
        await replay.socketFactory.enqueueConnectResult(.success(replacement))
        await replay.connection.enqueue(.failure(GameSocketTransportError()))
        await replay.service.waitUntilGetGamePending(1)
        let reconnectingPrompt = try #require(
            replay.model.basicChoicePresentation(for: replay.gameID)
        )
        #expect(reconnectingPrompt.ownerID == ownerID)
        #expect(reconnectingPrompt.identity != prompt.identity)
        #expect(!reconnectingPrompt.canRetry)
        #expect(await replay.model.retryBasicChoice(reconnectingPrompt.identity) == .staleQuestion)

        let restoredEnvelope = try CoverageEnvelopeBuilder.envelope(
            for: recording.record,
            baseEnvelopeData: fixtureData(named: "get-game"),
            runDefinition: runDefinition
        )
        await replay.service.resumeOldestGetGame(with: .success(restoredEnvelope))
        await replacement.waitUntilAwaitingNextEvent()
        let current = try #require(replay.model.basicChoicePresentation(for: replay.gameID))
        #expect(current.ownerID == ownerID)
        #expect(current.canRetry)
        #expect(current.actionChoiceIndex == choiceIndex)
        #expect(current.actionPhase == .retryable(.transportFailure))
        #expect(await replay.model.retryBasicChoice(prompt.identity) == .staleQuestion)
        await replacement.enqueueSendResult(.success(()))
        #expect(await replay.model.retryBasicChoice(current.identity) == .sentAwaitingSnapshot)
        #expect(
            await replay.model.submitBasicChoice(current.identity, choiceIndex: choiceIndex)
                == .alreadyPending
        )
        #expect(await replay.connection.sentData == [expectedAnswer])
        #expect(await replacement.sentData == [expectedAnswer])
    }

    @Test("Spectator socket snapshots do not correlate feedback to player prompts")
    func spectatorSocketSnapshotsDoNotCorrelateFeedbackToPlayerPrompts() async throws {
        let recording = try smokeRecording(named: "2p-smoke.jsonl")
        let runDefinition = try MultiplayerRunDefinition(fileName: recording.fileName)
        let catalogDocuments = try makeSyntheticCatalog(for: [recording])
        let replay = try await CoverageReplaySession.start(
            first: recording,
            baseEnvelopeData: fixtureData(named: "get-game"),
            catalogDocuments: catalogDocuments,
            deck: sampleDeck(),
            runDefinition: runDefinition
        )
        replay.model.liveGameParticipantIdentities[replay.gameID] = .spectator
        replay.model.setBasicChoiceServerFeedback(
            gameID: replay.gameID,
            message: "spectator feedback is not prompt-correlated",
            source: .answerRejected
        )

        let replacement = try smokeEnvelope(
            for: recording,
            runDefinition: runDefinition,
            investigatorNames: distinctInvestigatorNames,
            privatePromptMarker: "replacement prompt contents"
        )
        try await replay.connection.enqueue(.event(.message(
            ContractJSON.encode(BoardSnapshotUpdate.snapshot(replacement.game))
        )))
        await replay.connection.waitUntilAwaitingNextEvent()
        #expect(replay.model.basicChoiceServerFeedback[replay.gameID]
            == "spectator feedback is not prompt-correlated")
        #expect(replay.model.basicChoiceServerFeedbackSources[replay.gameID] == .answerRejected)

        replay.model.setBasicChoiceServerFeedback(
            gameID: replay.gameID,
            message: "game error feedback clears on the next authoritative snapshot",
            source: .gameError
        )
        let settled = try smokeEnvelope(
            for: recording,
            runDefinition: runDefinition,
            investigatorNames: distinctInvestigatorNames,
            privatePromptMarker: "settled prompt contents"
        )
        try await replay.connection.enqueue(.event(.message(
            ContractJSON.encode(BoardSnapshotUpdate.snapshot(settled.game))
        )))
        await replay.connection.waitUntilAwaitingNextEvent()
        #expect(replay.model.basicChoiceServerFeedback[replay.gameID] == nil)
        #expect(replay.model.basicChoiceServerFeedbackSources[replay.gameID] == nil)
    }

    @Test("Multiplayer status uses server fields from smoke snapshot bytes")
    func multiplayerStatusUsesServerFieldsFromSmokeSnapshotBytes() throws {
        let recording = try smokeRecording(named: "2p-smoke.jsonl")
        let runDefinition = try MultiplayerRunDefinition(fileName: recording.fileName)
        let envelope = try smokeEnvelope(
            for: recording,
            runDefinition: runDefinition,
            investigatorNames: distinctInvestigatorNames
        )
        let projection = BoardProjectionBuilder.makeProjection(from: envelope.game)
        let ownerID = try recording.record.recordedPlayerID()
        let waitingPlayerID = try runDefinition.seats[0].playerIDValue()

        #expect(projection.counters.playerCount == 2)
        #expect(projection.playerOrderCount == 2)
        #expect(projection.investigators.map(\.id.rawValue.rawValue) == ["c01001", "c01002"])
        #expect(projection.investigators.map(\.displayName) == ["Roland Banks", "Daisy Walker"])
        #expect(projection.investigators.map(\.isLeadInvestigator) == [true, false])
        #expect(projection.investigators.map(\.isActiveInvestigator) == [false, true])
        #expect(projection.investigators.map(\.isActingPlayer) == [false, true])
        #expect(projection.investigators.map(\.isTurnPlayer) == [false, true])
        #expect(projection.investigators.map(\.isMultiplayer) == [true, true])
        #expect(projection.investigators.map(\.hasPendingPrompt) == [false, true])

        let ownerStatus = BoardMultiplayerStatus(projection: projection, localPlayerID: ownerID)
        #expect(ownerStatus.shouldShowPromptSurface)
        #expect(ownerStatus.localPromptText == "Your prompt is ready.")
        #expect(ownerStatus.pendingPromptText == "Pending prompt: Daisy Walker")

        let waitingStatus = BoardMultiplayerStatus(
            projection: projection,
            localPlayerID: waitingPlayerID
        )
        #expect(waitingStatus.localPromptText == "Waiting for Daisy Walker.")
        #expect(waitingStatus.accessibilityLabel.contains("Turn: Daisy Walker"))

        let spectatorStatus = BoardMultiplayerStatus(
            projection: projection,
            localPlayerID: nil,
            isLocalSpectator: true
        )
        #expect(spectatorStatus.localPromptText == "Spectating. Waiting for Daisy Walker.")
        #expect(
            spectatorStatus.accessibilityLabel.contains("Spectating. Waiting for Daisy Walker.")
        )

        let unknownIdentityStatus = BoardMultiplayerStatus(
            projection: projection,
            localPlayerID: nil
        )
        #expect(unknownIdentityStatus.localPromptText == "Waiting for player identity.")
    }

    @Test("Multiplayer status distinguishes active from turn and handles no turn")
    func multiplayerStatusDistinguishesActiveFromTurnAndNoTurn() throws {
        let recording = try smokeRecording(named: "3p-smoke.jsonl")
        let runDefinition = try MultiplayerRunDefinition(fileName: recording.fileName)
        let envelope = try smokeEnvelope(
            for: recording,
            runDefinition: runDefinition,
            investigatorNames: distinctInvestigatorNames,
            activeInvestigatorID: "c01003",
            activePlayerID: runDefinition.seats[1].playerID,
            turnPlayerInvestigatorID: .string("c01002")
        )
        let projection = BoardProjectionBuilder.makeProjection(from: envelope.game)
        let status = BoardMultiplayerStatus(projection: projection, localPlayerID: nil)

        #expect(projection.investigators.map(\.displayName) == [
            "Roland Banks", "Daisy Walker", "Agnes Baker",
        ])
        #expect(projection.investigators.map(\.isActiveInvestigator) == [false, false, true])
        #expect(projection.investigators.map(\.isActingPlayer) == [false, true, false])
        #expect(projection.investigators.map(\.isTurnPlayer) == [false, true, false])
        #expect(status.actingText == "Acting: Daisy Walker")
        #expect(status.turnText == "Turn: Daisy Walker")

        let noTurnEnvelope = try smokeEnvelope(
            for: recording,
            runDefinition: runDefinition,
            investigatorNames: distinctInvestigatorNames,
            turnPlayerInvestigatorID: .null
        )
        let noTurnProjection = BoardProjectionBuilder.makeProjection(from: noTurnEnvelope.game)
        let noTurnStatus = BoardMultiplayerStatus(projection: noTurnProjection, localPlayerID: nil)
        #expect(noTurnProjection.investigators.map(\.isTurnPlayer) == [false, false, false])
        #expect(noTurnStatus.turnText == "Turn: No turn investigator")
    }

    @Test("Solo status stays hidden for smoke snapshot bytes")
    func soloStatusStaysHiddenForSmokeSnapshotBytes() throws {
        let recording = try #require(
            CoverageRecordingLoader.load(file: smokeFixtureURL()).records.first
        )
        let envelope = try CoverageEnvelopeBuilder.envelope(
            for: recording.record,
            baseEnvelopeData: fixtureData(named: "get-game")
        )
        let projection = BoardProjectionBuilder.makeProjection(from: envelope.game)
        let localPlayerID = try recording.record.recordedPlayerID()
        let status = BoardMultiplayerStatus(projection: projection, localPlayerID: localPlayerID)
        let investigator = try #require(projection.investigators.first)

        #expect(projection.playerOrderCount == 1)
        #expect(projection.questions.count == 1)
        #expect(!status.shouldShowPromptSurface)
        #expect(status.localPromptText == nil)
        #expect(!investigator.isMultiplayer)
        #expect(investigator.hasPendingPrompt)
        #expect(!BoardAccessibility.summary(investigator: investigator).contains("Pending prompt"))
    }

    @Test("Multiplayer status lists several pending players from additive snapshot bytes")
    // swiftlint:disable:next function_body_length
    func multiplayerStatusListsSeveralPendingPlayersFromAdditiveSnapshotBytes() throws {
        let recording = try smokeRecording(named: "4p-smoke.jsonl")
        let runDefinition = try MultiplayerRunDefinition(fileName: recording.fileName)
        let pendingPlayers = try runDefinition.seats.suffix(3).map { try $0.playerIDValue() }
        let envelope = try smokeEnvelope(
            for: recording,
            runDefinition: runDefinition,
            additionalPromptPlayerIDs: Array(pendingPlayers.dropLast()),
            injectAdditiveField: true,
            investigatorNames: distinctInvestigatorNames
        )
        let projection = BoardProjectionBuilder.makeProjection(from: envelope.game)
        let waitingPlayerID = try runDefinition.seats[0].playerIDValue()
        let status = BoardMultiplayerStatus(
            projection: projection,
            localPlayerID: waitingPlayerID
        )

        #expect(projection.questions.count == 3)
        #expect(projection.investigators.map(\.hasPendingPrompt) == [false, true, true, true])
        #expect(status.pendingPromptNames == ["Daisy Walker", "Agnes Baker", "Skids O'Toole"])
        #expect(
            status.localPromptText
                == "Waiting for Daisy Walker, Agnes Baker, and Skids O'Toole."
        )
        let spectatorStatus = BoardMultiplayerStatus(
            projection: projection,
            localPlayerID: nil,
            isLocalSpectator: true
        )
        #expect(
            spectatorStatus.localPromptText
                == "Spectating. Waiting for Daisy Walker, Agnes Baker, and Skids O'Toole."
        )
        CampaignPromptLocalization.$localizationIdentifierOverride.withValue("de") {
            let localized = BoardMultiplayerStatus(
                projection: projection,
                localPlayerID: waitingPlayerID
            )
            let localizedSpectator = BoardMultiplayerStatus(
                projection: projection,
                localPlayerID: nil,
                isLocalSpectator: true
            )
            #expect(localized.title == "Mehrspielerstatus")
            #expect(localized.actingText == "Aktiv: Skids O'Toole")
            #expect(
                localized.localPromptText == "Warten auf Daisy Walker, Agnes Baker und "
                    + "Skids O'Toole."
            )
            #expect(
                localizedSpectator.localPromptText == "Zuschauen. Warten auf Daisy Walker, "
                    + "Agnes Baker und Skids O'Toole."
            )
            #expect(localized.accessibilityLabel.contains("Mehrspielerstatus"))
        }
    }

    @Test("Multiplayer status never includes another player's prompt contents")
    func multiplayerStatusNeverIncludesAnotherPlayersPromptContents() throws {
        let secret = "PRIVATE PROMPT CONTENTS SHOULD NOT BE READ"
        let recording = try smokeRecording(named: "2p-smoke.jsonl")
        let runDefinition = try MultiplayerRunDefinition(fileName: recording.fileName)
        let envelope = try smokeEnvelope(
            for: recording,
            runDefinition: runDefinition,
            investigatorNames: distinctInvestigatorNames,
            privatePromptMarker: secret
        )
        let projection = BoardProjectionBuilder.makeProjection(from: envelope.game)
        let status = BoardMultiplayerStatus(
            projection: projection,
            localPlayerID: nil,
            isLocalSpectator: true
        )
        let combined = [
            status.title,
            status.actingText,
            status.turnText,
            status.leadText,
            status.pendingPromptText,
            status.localPromptText ?? "",
            status.accessibilityLabel,
        ].joined(separator: "\n")

        #expect(!combined.contains(secret))
        #expect(combined.contains("Daisy Walker"))
    }

    @Test("JSONL loader keeps physical line numbers across blanks and CRLF")
    func jsonlLoaderKeepsPhysicalLineNumbers() throws {
        let firstLine = try String(contentsOf: smokeFixtureURL(), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first
        let line = try #require(firstLine)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "notz-smoke-line-numbers-\(UUID().uuidString).jsonl"
        )
        try "\r\n\(line)\r\n".write(to: scratch, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let record = try #require(CoverageRecordingLoader.load(file: scratch).records.first)
        #expect(record.lineNumber == 2)
    }

    private func smokeFixtureURL() throws -> URL {
        try #require(
            Bundle.module.url(
                forResource: "smoke",
                withExtension: "jsonl",
                subdirectory: "Fixtures/NightOfTheZealotCoverageReplay"
            )
        )
    }

    private func multiplayerSmokeFixtureDirectoryURL() throws -> URL {
        try #require(
            Bundle.module.url(
                forResource: "NightOfTheZealotMultiplayerCoverageReplay",
                withExtension: nil,
                subdirectory: "Fixtures"
            )
        )
    }

    private var distinctInvestigatorNames: [String: String] {
        [
            "c01001": "Roland Banks",
            "c01002": "Daisy Walker",
            "c01003": "Agnes Baker",
            "c01004": "Skids O'Toole",
        ]
    }

    private func smokeRecording(named fileName: String) throws -> CoverageRecording {
        let recordings = try CoverageRecordingLoader.load(
            directory: multiplayerSmokeFixtureDirectoryURL()
        )
        return try #require(recordings.records.first { $0.fileName == fileName })
    }

    private func smokeEnvelope(
        for recording: CoverageRecording,
        runDefinition: MultiplayerRunDefinition,
        additionalPromptPlayerIDs: [PlayerID] = [],
        injectAdditiveField: Bool = false,
        investigatorNames: [String: String] = [:],
        activeInvestigatorID: String? = nil,
        activePlayerID: String? = nil,
        turnPlayerInvestigatorID: JSONValue? = nil,
        privatePromptMarker: String? = nil
    ) throws -> GetGameEnvelope {
        let envelope = try CoverageEnvelopeBuilder.envelope(
            for: recording.record,
            baseEnvelopeData: fixtureData(named: "get-game"),
            runDefinition: runDefinition
        )
        var root = try ContractJSON.decode(JSONValue.self, from: ContractJSON.encode(envelope))
        guard case var .object(rootObject) = root,
              case var .object(game) = rootObject["game"],
              case var .object(questions) = game["question"],
              case var .object(presentations) = game["questionPresentation"]
        else { throw TestFailure() }

        applyInvestigatorNames(investigatorNames, to: &game)
        if let activeInvestigatorID {
            game["activeInvestigatorId"] = .string(activeInvestigatorID)
        }
        if let activePlayerID {
            game["activePlayerId"] = .string(activePlayerID)
        }
        if let turnPlayerInvestigatorID {
            game["turnPlayerInvestigatorId"] = turnPlayerInvestigatorID
        }

        let rawQuestion = rawQuestion(recording.record.rawQuestion, marker: privatePromptMarker)
        if privatePromptMarker != nil {
            for key in questions.keys {
                questions[key] = rawQuestion
            }
        }
        for playerID in additionalPromptPlayerIDs {
            let key = playerID.codingKey.stringValue
            questions[key] = rawQuestion
            presentations[key] = recording.record.questionPresentation
        }
        if injectAdditiveField {
            game["futureWhoseTurnField"] = .object(["ignored": .bool(true)])
        }
        game["question"] = .object(questions)
        game["questionPresentation"] = .object(presentations)
        rootObject["game"] = .object(game)
        root = .object(rootObject)
        return try ContractJSON.decode(GetGameEnvelope.self, from: ContractJSON.encode(root))
    }

    private func applyInvestigatorNames(
        _ names: [String: String],
        to game: inout [String: JSONValue]
    ) {
        guard !names.isEmpty, case var .object(investigators)? = game["investigators"] else {
            return
        }
        for (investigatorID, name) in names {
            guard case var .object(investigator)? = investigators[investigatorID] else { continue }
            investigator["name"] = .object(["subtitle": .null, "title": .string(name)])
            investigators[investigatorID] = .object(investigator)
        }
        game["investigators"] = .object(investigators)
    }

    private func rawQuestion(_ value: JSONValue, marker: String?) -> JSONValue {
        guard let marker, case var .object(object) = value else { return value }
        object["privatePromptContents"] = .string(marker)
        return .object(object)
    }

    private func run(recordings: CoverageRecordings) async throws {
        let catalogDocuments = try makeSyntheticCatalog(for: recordings.records)
        let baseEnvelopeData = try fixtureData(named: "get-game")
        let deck = try sampleDeck()
        var failures: [CoverageReplayPromptFailure] = []

        for group in recordings.groupsByFile() {
            guard let first = group.records.first else { continue }
            let replay = try await CoverageReplaySession.start(
                first: first,
                baseEnvelopeData: baseEnvelopeData,
                catalogDocuments: catalogDocuments,
                deck: deck
            )
            for (index, record) in group.records.enumerated() {
                do {
                    if index > 0 {
                        try await replay.show(record)
                    }
                    try await replay.verify(record)
                } catch let failure as CoverageReplayPromptFailure {
                    failures.append(failure)
                } catch {
                    failures.append(CoverageReplayPromptFailure(
                        record: record,
                        reason: String(describing: error)
                    ))
                }
            }
        }

        if !failures.isEmpty {
            throw CoverageReplayFailure(failures: failures)
        }
    }

    private func runMultiplayer(recordings: CoverageRecordings) async throws {
        let catalogDocuments = try makeSyntheticCatalog(for: recordings.records)
        let baseEnvelopeData = try fixtureData(named: "get-game")
        let deck = try sampleDeck()
        var failures: [CoverageReplayPromptFailure] = []

        for group in recordings.groupsByFile() {
            guard let first = group.records.first else { continue }
            let runDefinition: MultiplayerRunDefinition
            let replay: CoverageReplaySession
            do {
                runDefinition = try MultiplayerRunDefinition(fileName: group.fileName)
                replay = try await CoverageReplaySession.start(
                    first: first,
                    baseEnvelopeData: baseEnvelopeData,
                    catalogDocuments: catalogDocuments,
                    deck: deck,
                    runDefinition: runDefinition
                )
            } catch let failure as CoverageReplayPromptFailure {
                failures.append(failure)
                continue
            } catch {
                failures.append(CoverageReplayPromptFailure(
                    record: first,
                    reason: String(describing: error)
                ))
                continue
            }
            for (index, record) in group.records.enumerated() {
                do {
                    if index > 0 {
                        try await replay.show(record)
                    }
                    try await replay.verifyMultiplayer(record, runDefinition: runDefinition)
                } catch let failure as CoverageReplayPromptFailure {
                    failures.append(failure)
                } catch {
                    failures.append(CoverageReplayPromptFailure(
                        record: record,
                        reason: String(describing: error)
                    ))
                }
            }
        }

        if !failures.isEmpty {
            throw CoverageReplayFailure(failures: failures)
        }
    }

    private func submit(
        _ submission: RecordedCoverageSubmission,
        prompt: BasicChoicePromptPresentation,
        model: AppModel
    ) async -> BasicChoiceSubmitResult {
        switch submission {
        case let .singleChoice(choice):
            await model.submitBasicChoice(prompt.identity, choiceIndex: choice)
        case let .amounts(amounts):
            await model.submitAmountsAnswer(prompt.identity, amounts: amounts)
        case let .paymentAmounts(amounts):
            await model.submitPaymentAmountsAnswer(prompt.identity, amounts: amounts)
        case let .exchangeAmount(amount):
            await model.submitExchangeAmountsAnswer(prompt.identity, amount: amount)
        case let .continueCampaign(step):
            await model.submitContinueCampaignAnswer(prompt.identity, step: step)
        case .unsupported:
            .unsupportedChoice
        }
    }

    private func fixtureData(named fileName: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: fileName,
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try Data(contentsOf: url)
    }

    private func sampleDeck() throws -> Deck {
        struct DeckFixture: Decodable {
            let deck: Deck
        }
        return try ContractJSON.decode(DeckFixture.self, from: fixtureData(named: "decks")).deck
    }

    /// This synthetic catalog keeps replay focused on prompt decoding, routing, rendering,
    /// and answer submission. It intentionally creates placeholder text for every key the
    /// recordings mention, so a green replay does not prove locale-catalog key coverage or
    /// variable-shape compatibility.
    private func makeSyntheticCatalog(
        for records: [CoverageRecording]
    ) throws -> SyntheticLocaleCatalogDocuments {
        var keys = Set<String>()
        for record in records {
            collectLocalizationKeys(from: record.record.rawQuestion, into: &keys)
            collectLocalizationKeys(from: record.record.questionPresentation, into: &keys)
        }
        if keys.isEmpty {
            keys.insert("notz.coverage.synthetic")
        }
        let sortedKeys = keys.sorted()
        let entries = Dictionary(uniqueKeysWithValues: sortedKeys.map { key in
            (
                key,
                [
                    "form": "message",
                    "nodes": [["type": "text", "value": key]],
                    "variables": [],
                ] as [String: Any]
            )
        })
        let entryData = try JSONSerialization.data(
            withJSONObject: entries,
            options: [.sortedKeys]
        )
        let chunkEntries = try #require(String(data: entryData, encoding: .utf8))
        return try SyntheticLocaleCatalogDocuments.make(
            pack: "nightOfTheZealotCoverage",
            entryKeys: sortedKeys,
            chunkEntries: chunkEntries
        )
    }

    private func collectLocalizationKeys(
        from value: JSONValue,
        into keys: inout Set<String>
    ) {
        switch value {
        case .null, .bool, .number:
            break
        case let .string(text):
            insertLocalizationKey(text, into: &keys)
        case let .array(values):
            for value in values {
                collectLocalizationKeys(from: value, into: &keys)
            }
        case let .object(object):
            if case let .string(key)? = object["key"] {
                insertLocalizationKey(key, into: &keys)
            }
            collectChooseAmountsLabelKeys(from: object, into: &keys)
            for value in object.values {
                collectLocalizationKeys(from: value, into: &keys)
            }
        }
    }

    private func collectChooseAmountsLabelKeys(
        from object: [String: JSONValue],
        into keys: inout Set<String>
    ) {
        guard case let .array(choices)? = object["amountChoices"] else { return }
        for choice in choices {
            guard let label = choice.objectValue?["label"]?.stringValue,
                  label.hasPrefix("$"),
                  let key = StoryNarrativeLocalization.productionChoiceLabelCatalogKey(
                      "$choice.\(label.dropFirst())"
                  )
            else { continue }
            keys.insert(key)
        }
    }

    private func insertLocalizationKey(_ raw: String, into keys: inout Set<String>) {
        let key = raw.hasPrefix("$") ? String(raw.dropFirst()) : raw
        guard !key.isEmpty, key.contains(".") || raw.hasPrefix("$") else { return }
        keys.insert(key)
    }
}

@MainActor
// swiftlint:disable:next type_body_length
private struct CoverageReplaySession {
    let model: AppModel
    let connection: FakeGameSocketConnection
    let service: ScriptedGameLifecycleService
    let socketFactory: FakeGameSocketFactory
    let gameID: GameID
    let baseEnvelopeData: Data
    let deck: Deck
    let runDefinition: MultiplayerRunDefinition?

    static func start(
        first: CoverageRecording,
        baseEnvelopeData: Data,
        catalogDocuments: SyntheticLocaleCatalogDocuments,
        deck: Deck,
        runDefinition: MultiplayerRunDefinition? = nil
    ) async throws -> CoverageReplaySession {
        let (model, fakes) = makeModel(catalogDocuments: catalogDocuments)
        await model.flowTask?.value
        await model.localeCatalogTask?.value
        let envelope = try CoverageEnvelopeBuilder.envelope(
            for: first.record,
            baseEnvelopeData: baseEnvelopeData,
            runDefinition: runDefinition
        )
        let connection = FakeGameSocketConnection()
        await fakes.socketFactory.enqueueConnectResult(.success(connection))
        await fakes.service.enqueueGetGameResult(.success(envelope))
        _ = model.subscribeToLiveGame(envelope.game.id)
        await connection.waitUntilAwaitingNextEvent()
        return CoverageReplaySession(
            model: model,
            connection: connection,
            service: fakes.service,
            socketFactory: fakes.socketFactory,
            gameID: envelope.game.id,
            baseEnvelopeData: baseEnvelopeData,
            deck: deck,
            runDefinition: runDefinition
        )
    }

    func show(_ recording: CoverageRecording) async throws {
        let envelope = try CoverageEnvelopeBuilder.envelope(
            for: recording.record,
            baseEnvelopeData: baseEnvelopeData,
            runDefinition: runDefinition
        )
        try await connection.enqueue(.event(.message(
            ContractJSON.encode(BoardSnapshotUpdate.snapshot(envelope.game))
        )))
        await connection.waitUntilAwaitingNextEvent()
    }

    func verify(_ recording: CoverageRecording) async throws {
        let record = recording.record
        let prompt = try requirePrompt(for: recording)
        if LiveChooseDeckQuestion.matches(prompt.identity.rawQuestion) {
            try await verifyLiveChooseDeck(recording, prompt: prompt)
            return
        }
        if prompt.isChooseUpgradeDeckPrompt {
            try await verifyChooseUpgradeDeck(recording, prompt: prompt)
            return
        }
        guard prompt.isRenderableQuestion else {
            throw CoverageReplayPromptFailure(
                record: recording,
                reason: "prompt is not renderable in the current client"
            )
        }
        guard prompt.readOnlyReason == nil else {
            throw CoverageReplayPromptFailure(
                record: recording,
                reason: "prompt is read-only: \(String(describing: prompt.readOnlyReason))"
            )
        }

        let submission = try RecordedCoverageSubmission(answer: record.chosenAnswer)
        let sentBefore = await connection.sentData.count
        await connection.enqueueSendResult(.success(()))
        let result = await submit(submission, prompt: prompt)
        guard result == .sentAwaitingSnapshot else {
            throw CoverageReplayPromptFailure(
                record: recording,
                reason: "recorded answer was not actionable: \(result)"
            )
        }
        let sent = await connection.sentData
        guard sent.count == sentBefore + 1, let actual = sent.last else {
            throw CoverageReplayPromptFailure(
                record: recording,
                reason: "submission did not send exactly one answer frame"
            )
        }
        let expected = try ContractJSON.encode(record.chosenAnswer)
        guard actual == expected else {
            let expectedText = String(data: expected, encoding: .utf8) ?? "<non-UTF8>"
            let actualText = String(data: actual, encoding: .utf8) ?? "<non-UTF8>"
            throw CoverageReplayPromptFailure(
                record: recording,
                reason: "sent answer bytes differ; expected \(expectedText) got \(actualText)"
            )
        }
    }

    func verifyMultiplayer(
        _ recording: CoverageRecording,
        runDefinition: MultiplayerRunDefinition
    ) async throws {
        let ownerID = try recording.record.recordedPlayerID()
        guard let ownerSeat = runDefinition.seat(playerID: recording.record.playerID) else {
            throw CoverageReplayPromptFailure(
                record: recording,
                reason: "record owner is not part of the multiplayer run"
            )
        }
        guard ownerSeat.investigator == recording.record.investigator else {
            throw CoverageReplayPromptFailure(
                record: recording,
                reason: "record owner/investigator pair was " +
                    "\(recording.record.playerID)/\(recording.record.investigator); " +
                    "expected investigator \(ownerSeat.investigator)"
            )
        }

        model.liveGameParticipantIdentities[gameID] = .participant(ownerID)
        let ownerPrompt = try requirePrompt(for: recording)

        for seat in runDefinition.seats where seat.playerID != recording.record.playerID {
            try await verifyCannotAnswer(
                recording,
                ownerPrompt: ownerPrompt,
                identity: .participant(seat.playerIDValue()),
                expectedReasonIfPresented: .anotherPlayer,
                roleDescription: "participant \(seat.playerID)"
            )
        }
        try await verifyCannotAnswer(
            recording,
            ownerPrompt: ownerPrompt,
            identity: .spectator,
            expectedReasonIfPresented: .spectator,
            roleDescription: "spectator"
        )

        model.liveGameParticipantIdentities[gameID] = .participant(ownerID)
        try await verify(recording)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func verifyCannotAnswer(
        _ recording: CoverageRecording,
        ownerPrompt: BasicChoicePromptPresentation,
        identity: LiveGameParticipantIdentity,
        expectedReasonIfPresented: BasicChoiceReadOnlyReason,
        roleDescription: String
    ) async throws {
        model.liveGameParticipantIdentities[gameID] = identity
        let presentedPrompt = model.basicChoicePresentation(for: gameID)
        if case .spectator = identity {
            guard presentedPrompt == nil else {
                throw CoverageReplayPromptFailure(
                    record: recording,
                    reason: "spectator saw another player's prompt contents"
                )
            }
        } else if let presentedPrompt {
            let ownerID = try recording.record.recordedPlayerID()
            guard presentedPrompt.ownerID == ownerID else {
                throw CoverageReplayPromptFailure(
                    record: recording,
                    reason: "\(roleDescription) saw prompt for " +
                        "\(presentedPrompt.ownerID) instead of \(ownerID)"
                )
            }
            guard presentedPrompt.readOnlyReason == expectedReasonIfPresented else {
                throw CoverageReplayPromptFailure(
                    record: recording,
                    reason: "\(roleDescription) read-only reason was " +
                        "\(String(describing: presentedPrompt.readOnlyReason)); " +
                        "expected \(expectedReasonIfPresented)"
                )
            }
        }

        let sentBefore = await connection.sentData.count
        let serviceCallsBefore = await service.callOrder.count
        let attemptPrompt = presentedPrompt ?? ownerPrompt
        if LiveChooseDeckQuestion.matches(attemptPrompt.identity.rawQuestion) {
            guard case .readOnly = model.canAnswerLiveChooseDeck(for: gameID) else {
                throw CoverageReplayPromptFailure(
                    record: recording,
                    reason: "\(roleDescription) could answer ChooseDeck prompt"
                )
            }
            guard await model.chooseDeckForLivePrompt(deck, in: gameID) == false else {
                throw CoverageReplayPromptFailure(
                    record: recording,
                    reason: "\(roleDescription) sent ChooseDeck prompt"
                )
            }
        } else if attemptPrompt.isChooseUpgradeDeckPrompt {
            let result = await model.continueCampaignWithoutUpgrading(
                investigatorId: recording.record.investigator,
                in: gameID,
                promptIdentity: attemptPrompt.identity
            )
            guard case .failed = result else {
                throw CoverageReplayPromptFailure(
                    record: recording,
                    reason: "\(roleDescription) submitted ChooseUpgradeDeck prompt: \(result)"
                )
            }
        } else {
            let submission = try RecordedCoverageSubmission(answer: recording.record.chosenAnswer)
            let result = await submit(submission, prompt: attemptPrompt)
            guard result.isRejected else {
                throw CoverageReplayPromptFailure(
                    record: recording,
                    reason: "\(roleDescription) submitted prompt: \(result)"
                )
            }
        }

        let sentAfter = await connection.sentData.count
        guard sentAfter == sentBefore else {
            throw CoverageReplayPromptFailure(
                record: recording,
                reason: "\(roleDescription) sent \(sentAfter - sentBefore) frame(s)"
            )
        }
        let serviceCallsAfter = await service.callOrder.count
        guard serviceCallsAfter == serviceCallsBefore else {
            throw CoverageReplayPromptFailure(
                record: recording,
                reason: "\(roleDescription) made a REST call"
            )
        }
    }

    private func verifyLiveChooseDeck(
        _ recording: CoverageRecording,
        prompt: BasicChoicePromptPresentation
    ) async throws {
        guard recording.record.answerTag == "DeckListAnswer" else {
            let tag = recording.record.answerTag ?? "nil"
            throw CoverageReplayPromptFailure(
                record: recording,
                reason: "ChooseDeck recording used unexpected answer \(tag)"
            )
        }
        guard case let .canAnswer(promptKey) = model.canAnswerLiveChooseDeck(for: gameID),
              promptKey == prompt.identity.promptKey
        else {
            throw CoverageReplayPromptFailure(
                record: recording,
                reason: "live ChooseDeck prompt was not actionable"
            )
        }

        let sentBefore = await connection.sentData.count
        await connection.enqueueSendResult(.success(()))
        guard await model.chooseDeckForLivePrompt(deck, in: gameID) else {
            throw CoverageReplayPromptFailure(
                record: recording,
                reason: "live ChooseDeck submission returned false"
            )
        }
        let sent = await connection.sentData
        guard sent.count == sentBefore + 1, let actual = sent.last else {
            throw CoverageReplayPromptFailure(
                record: recording,
                reason: "ChooseDeck submission did not send exactly one answer frame"
            )
        }
        let decoded = try ContractJSON.decode(DeckAnswer.self, from: actual)
        let playerID = try recording.record.recordedPlayerID()
        guard decoded == DeckAnswer(deckId: deck.id, playerId: playerID) else {
            throw CoverageReplayPromptFailure(
                record: recording,
                reason: "ChooseDeck sent \(decoded) instead of deck \(deck.id) for \(playerID)"
            )
        }
        // The server corpus records DeckListAnswer because the bot submits an inline starter
        // deck. The Apple app's UI path sends DeckAnswer for a saved deck ID, so this route
        // is actionable but intentionally not byte-comparable with the recorded answer.
    }

    private func verifyChooseUpgradeDeck(
        _ recording: CoverageRecording,
        prompt: BasicChoicePromptPresentation
    ) async throws {
        guard recording.record.answerTag == "DeckListAnswer" else {
            let tag = recording.record.answerTag ?? "nil"
            throw CoverageReplayPromptFailure(
                record: recording,
                reason: "ChooseUpgradeDeck recording used unexpected answer \(tag)"
            )
        }
        let sentBefore = await connection.sentData.count
        await service.enqueueChooseDeckResult(.success(()))
        let result = await model.continueCampaignWithoutUpgrading(
            investigatorId: recording.record.investigator,
            in: gameID,
            promptIdentity: prompt.identity
        )
        guard result == .submitted else {
            throw CoverageReplayPromptFailure(
                record: recording,
                reason: "ChooseUpgradeDeck REST submission was not actionable: \(result)"
            )
        }
        let sent = await connection.sentData
        guard sent.count == sentBefore else {
            throw CoverageReplayPromptFailure(
                record: recording,
                reason: "ChooseUpgradeDeck used WebSocket instead of the REST deck route"
            )
        }
        let request = await service.lastChooseDeckRequest
        guard request?.investigatorId.rawValue == recording.record.investigator,
              request?.deckUrl == nil,
              request?.deckList == nil
        else {
            throw CoverageReplayPromptFailure(
                record: recording,
                reason: "ChooseUpgradeDeck did not submit a nil deck source for the investigator"
            )
        }
        // The server records a DeckListAnswer for this prompt family, while the Apple app's
        // between-scenario UI routes continuation without upgrades through the REST deck PUT.
    }

    private func requirePrompt(
        for recording: CoverageRecording
    ) throws -> BasicChoicePromptPresentation {
        guard let prompt = model.basicChoicePresentation(for: gameID) else {
            throw CoverageReplayPromptFailure(
                record: recording,
                reason: "AppModel exposed no prompt for the recorded player"
            )
        }
        guard prompt.questionVersion == recording.record.questionVersion else {
            throw CoverageReplayPromptFailure(
                record: recording,
                reason: "AppModel prompt version \(prompt.questionVersion) did not match recording"
            )
        }
        return prompt
    }

    private func submit(
        _ submission: RecordedCoverageSubmission,
        prompt: BasicChoicePromptPresentation
    ) async -> BasicChoiceSubmitResult {
        switch submission {
        case let .singleChoice(choice):
            await model.submitBasicChoice(prompt.identity, choiceIndex: choice)
        case let .amounts(amounts):
            await model.submitAmountsAnswer(prompt.identity, amounts: amounts)
        case let .paymentAmounts(amounts):
            await model.submitPaymentAmountsAnswer(prompt.identity, amounts: amounts)
        case let .exchangeAmount(amount):
            await model.submitExchangeAmountsAnswer(prompt.identity, amount: amount)
        case let .continueCampaign(step):
            await model.submitContinueCampaignAnswer(prompt.identity, step: step)
        case .unsupported:
            .unsupportedChoice
        }
    }

    private struct Fakes {
        let service: ScriptedGameLifecycleService
        let socketFactory: FakeGameSocketFactory
    }

    private static func makeModel(
        catalogDocuments: SyntheticLocaleCatalogDocuments
    ) -> (model: AppModel, fakes: Fakes) {
        let tokenStore = FakeTokenStore(tokens: [catalogDocuments.profile.id: "notz-token"])
        let service = ScriptedGameLifecycleService()
        let socketFactory = FakeGameSocketFactory()
        let model = AppModel(
            profileStore: FakeServerProfileStore(
                profiles: [.hosted, catalogDocuments.profile],
                selectedID: catalogDocuments.profile.id
            ),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.compatible(
                capabilities: [LocaleCatalogLimits.capabilityIdentifier],
                localeCatalog: catalogDocuments.advertisement
            ))),
            authenticationSession: ScriptedAuthenticating(
                authenticateResult: .success(AuthToken(token: "replacement-token")),
                currentUserResult: .success(.sample)
            ),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            gameLifecycleService: service,
            liveGameSocketFactory: socketFactory,
            liveGameClock: FakeLiveGameClock(),
            liveGameRandomSource: FakeLiveGameRandomSource(values: [0]),
            localeCatalogLoader: catalogDocuments.loader(),
            preferredLanguagesProvider: NightOfTheZealotPreferredLanguages()
        )
        return (model, Fakes(service: service, socketFactory: socketFactory))
    }
}

private struct CoverageRecord: Decodable {
    let scenario: JSONValue
    let scenarioKey: String
    let investigator: String
    let stepIndex: Int
    let questionVersion: Int
    let playerID: String
    let rawQuestion: JSONValue
    let questionPresentation: JSONValue
    let chosenAnswer: JSONValue

    var answerTag: String? {
        guard case let .object(object) = chosenAnswer,
              case let .string(tag)? = object["tag"]
        else { return nil }
        return tag
    }

    func recordedPlayerID() throws -> PlayerID {
        guard let uuid = UUID(uuidString: playerID) else { throw TestFailure() }
        return PlayerID(uuid)
    }

    private enum CodingKeys: String, CodingKey {
        case scenario
        case scenarioKey
        case investigator
        case stepIndex
        case questionVersion
        case playerID = "playerId"
        case rawQuestion
        case questionPresentation
        case chosenAnswer
    }
}

private struct CoverageRecording {
    let fileName: String
    let lineNumber: Int
    let record: CoverageRecord

    var runDescription: String {
        if let playerCount = MultiplayerRunDefinition.playerCount(fileName: fileName) {
            return "\(playerCount)p"
        }
        return "solo"
    }
}

private struct CoverageRecordingGroup {
    let fileName: String
    let records: [CoverageRecording]
}

private struct CoverageRecordings {
    let records: [CoverageRecording]

    func groupsByFile() -> [CoverageRecordingGroup] {
        let grouped = Dictionary(grouping: records, by: \.fileName)
        return grouped.keys.sorted().map { fileName in
            CoverageRecordingGroup(
                fileName: fileName,
                records: grouped[fileName]?.sorted {
                    $0.lineNumber < $1.lineNumber
                } ?? []
            )
        }
    }
}

private struct MultiplayerSeat {
    let playerID: String
    let investigator: String

    func playerIDValue() throws -> PlayerID {
        guard let uuid = UUID(uuidString: playerID) else {
            throw CoverageReplayFailure(message: "Invalid multiplayer seat playerId \(playerID)")
        }
        return PlayerID(uuid)
    }
}

private struct MultiplayerRunDefinition {
    let playerCount: Int
    let seats: [MultiplayerSeat]

    init(fileName: String) throws {
        guard let count = Self.playerCount(fileName: fileName) else {
            throw CoverageReplayFailure(message: "Could not infer multiplayer run from \(fileName)")
        }
        playerCount = count
        seats = (1 ... count).map { index in
            MultiplayerSeat(
                playerID: String(
                    format: "00000000-0000-0000-0000-%04d%08d",
                    count,
                    index
                ),
                investigator: Self.investigatorIDs[index - 1]
            )
        }
    }

    private static let investigatorIDs = ["c01001", "c01002", "c01003", "c01004"]

    func seat(playerID: String) -> MultiplayerSeat? {
        seats.first { $0.playerID == playerID }
    }

    static func playerCount(fileName: String) -> Int? {
        guard let first = fileName.first,
              let count = Int(String(first)),
              (2 ... 4).contains(count),
              fileName.dropFirst().first == "p"
        else { return nil }
        return count
    }
}

private enum CoverageRecordingLoader {
    static func load(directory: URL) throws -> CoverageRecordings {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ).filter { url in
            url.pathExtension == "jsonl" && (try? url.resourceValues(
                forKeys: [.isRegularFileKey]
            ).isRegularFile) == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !urls.isEmpty else {
            throw CoverageReplayFailure(message: "No .jsonl files found in \(directory.path)")
        }
        return try load(files: urls)
    }

    static func load(file: URL) throws -> CoverageRecordings {
        try load(files: [file])
    }

    private static func load(files urls: [URL]) throws -> CoverageRecordings {
        var records: [CoverageRecording] = []
        for url in urls {
            let text = try String(contentsOf: url, encoding: .utf8)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            for (offset, line) in text.split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).enumerated() {
                guard !line.isEmpty else { continue }
                let data = Data(line.utf8)
                try records.append(CoverageRecording(
                    fileName: url.lastPathComponent,
                    lineNumber: offset + 1,
                    record: ContractJSON.decode(CoverageRecord.self, from: data)
                ))
            }
        }
        guard !records.isEmpty else {
            throw CoverageReplayFailure(message: "Coverage JSONL input contained no records")
        }
        return CoverageRecordings(records: records)
    }
}

private enum CoverageEnvelopeBuilder {
    static func envelope(
        for record: CoverageRecord,
        baseEnvelopeData: Data,
        runDefinition: MultiplayerRunDefinition? = nil
    ) throws -> GetGameEnvelope {
        var root = try ContractJSON.decode(JSONValue.self, from: baseEnvelopeData)
        guard case var .object(rootObject) = root,
              case var .object(game) = rootObject["game"]
        else { throw TestFailure() }

        if let runDefinition {
            try rewriteMultiplayerOwnership(for: record, runDefinition: runDefinition, in: &game)
            rootObject["multiplayerMode"] = .string("WithFriends")
        } else {
            try rewriteOwnership(for: record, in: &game)
        }
        rootObject["playerId"] = .string(record.playerID)
        game["activePlayerId"] = .string(record.playerID)
        game["activeInvestigatorId"] = .string(record.investigator)
        game["turnPlayerInvestigatorId"] = .string(record.investigator)
        game["scenarioSteps"] = .number(.integer(Int64(record.questionVersion)))
        game["question"] = .object([record.playerID: record.rawQuestion])
        game["questionPresentation"] = .object([
            record.playerID: record.questionPresentation,
        ])
        if case let .continueCampaign(step) = try? RecordedCoverageSubmission(
            answer: record.chosenAnswer
        ) {
            // The coverage record stores the answer step but not the campaign snapshot that
            // advertised it. Patch the synthetic snapshot so AppModel verifies the submitted
            // step against server-published state instead of a client-synthesized value.
            patchCampaignStep(step, in: &game)
        }
        rootObject["game"] = .object(game)
        root = .object(rootObject)
        return try ContractJSON.decode(GetGameEnvelope.self, from: ContractJSON.encode(root))
    }

    private static func rewriteOwnership(
        for record: CoverageRecord,
        in game: inout [String: JSONValue]
    ) throws {
        guard case let .object(investigators)? = game["investigators"],
              let templateInvestigator = investigators.keys.min(),
              case let .string(templatePlayer)? = game["activePlayerId"]
        else { throw TestFailure() }

        let value = replaceStringValues(
            .object(game),
            replacements: [
                templateInvestigator: record.investigator,
                templatePlayer: record.playerID,
            ]
        )
        guard case var .object(rewrittenGame) = value else { throw TestFailure() }
        for field in [
            "investigators", "otherInvestigators", "killedInvestigators",
            "retiredInvestigators",
        ] {
            renameObjectKey(
                field,
                from: templateInvestigator,
                to: record.investigator,
                in: &rewrittenGame
            )
        }
        game = rewrittenGame
    }

    private static func rewriteMultiplayerOwnership(
        for record: CoverageRecord,
        runDefinition: MultiplayerRunDefinition,
        in game: inout [String: JSONValue]
    ) throws {
        guard case let .object(investigators)? = game["investigators"],
              let templateInvestigator = investigators.keys.min(),
              let templateInvestigatorValue = investigators[templateInvestigator],
              case let .string(templatePlayer)? = game["activePlayerId"]
        else {
            throw CoverageReplayFailure(
                message: "Base get-game fixture does not contain ownership fields"
            )
        }

        var rewrittenInvestigators: [String: JSONValue] = [:]
        for seat in runDefinition.seats {
            rewrittenInvestigators[seat.investigator] = replaceStringValues(
                templateInvestigatorValue,
                replacements: [
                    templateInvestigator: seat.investigator,
                    templatePlayer: seat.playerID,
                ]
            )
        }

        game["playerCount"] = .number(.integer(Int64(runDefinition.playerCount)))
        game["multiplayerVariant"] = .string("WithFriends")
        game["investigators"] = .object(rewrittenInvestigators)
        game["otherInvestigators"] = .object([:])
        game["killedInvestigators"] = .object([:])
        game["retiredInvestigators"] = .object([:])
        game["playerOrder"] = .array(runDefinition.seats.map { .string($0.investigator) })
        game["leadInvestigatorId"] = .string(runDefinition.seats[0].investigator)

        guard let ownerSeat = runDefinition.seat(playerID: record.playerID) else {
            throw CoverageReplayFailure(
                message: "Record owner \(record.playerID) is not seated in this run"
            )
        }
        guard ownerSeat.investigator == record.investigator else {
            throw CoverageReplayFailure(
                message: "Record owner \(record.playerID) belongs to " +
                    "\(ownerSeat.investigator), not \(record.investigator)"
            )
        }
    }

    private static func renameObjectKey(
        _ field: String,
        from oldKey: String,
        to newKey: String,
        in object: inout [String: JSONValue]
    ) {
        guard case var .object(map)? = object[field], let value = map.removeValue(forKey: oldKey)
        else { return }
        map[newKey] = value
        object[field] = .object(map)
    }

    private static func replaceStringValues(
        _ value: JSONValue,
        replacements: [String: String]
    ) -> JSONValue {
        switch value {
        case let .string(text):
            replacements[text].map(JSONValue.string) ?? value
        case let .array(values):
            .array(values.map { replaceStringValues($0, replacements: replacements) })
        case let .object(object):
            .object(object.mapValues { replaceStringValues($0, replacements: replacements) })
        case .null, .bool, .number:
            value
        }
    }

    private static func patchCampaignStep(
        _ step: JSONValue,
        in game: inout [String: JSONValue]
    ) {
        guard case var .object(mode)? = game["mode"],
              case var .object(scenario)? = mode["That"]
        else { return }
        scenario["campaignStep"] = step
        mode["That"] = .object(scenario)
        game["mode"] = .object(mode)
    }
}

private extension BasicChoiceSubmitResult {
    var isRejected: Bool {
        switch self {
        case .sentAwaitingSnapshot, .alreadyPending, .retryableFailure:
            false
        case .staleQuestion, .readOnly, .unsupportedChoice:
            true
        }
    }
}

private enum RecordedCoverageSubmission: Equatable {
    case singleChoice(Int)
    case amounts([String: Int])
    case paymentAmounts([String: Int])
    case exchangeAmount(Int)
    case continueCampaign(JSONValue)
    case unsupported(String)

    init(answer: JSONValue) throws {
        guard case let .object(object) = answer,
              case let .string(tag)? = object["tag"]
        else { throw TestFailure() }
        switch tag {
        case "Answer":
            self = try .singleChoice(Self.choice(in: object))
        case "AmountsAnswer":
            self = try .amounts(Self.amounts(in: object))
        case "PaymentAmountsAnswer":
            self = try .paymentAmounts(Self.amounts(in: object))
        case "ExchangeAmountsAnswer":
            self = try .exchangeAmount(Self.integer(object["amount"]))
        case "CampaignStepAnswer":
            self = try .continueCampaign(Self.required(object["contents"]))
        default:
            self = .unsupported(tag)
        }
    }

    private static func choice(in object: [String: JSONValue]) throws -> Int {
        guard case let .object(contents)? = object["contents"] else { throw TestFailure() }
        return try integer(contents["choice"])
    }

    private static func amounts(in object: [String: JSONValue]) throws -> [String: Int] {
        guard case let .object(contents)? = object["contents"],
              case let .object(amounts)? = contents["amounts"]
        else { throw TestFailure() }
        return try amounts.mapValues { try integer($0) }
    }

    private static func required(_ value: JSONValue?) throws -> JSONValue {
        guard let value else { throw TestFailure() }
        return value
    }

    private static func integer(_ value: JSONValue?) throws -> Int {
        guard case let .number(number)? = value,
              number.sign == .plus,
              let raw = number.rawToken,
              let integer = Int(raw)
        else { throw TestFailure() }
        return integer
    }
}

private struct CoverageReplayPromptFailure: Error, CustomStringConvertible {
    let record: CoverageRecording
    let reason: String

    var description: String {
        "\(record.fileName):\(record.lineNumber) run=\(record.runDescription) " +
            "owner=\(record.record.playerID) scenario=\(record.record.scenarioKey) " +
            "investigator=\(record.record.investigator) stepIndex=" +
            "\(record.record.stepIndex) questionVersion=" +
            "\(record.record.questionVersion): \(reason)"
    }
}

private struct CoverageReplayFailure: Error, CustomStringConvertible {
    let message: String
    let failures: [CoverageReplayPromptFailure]

    init(message: String) {
        self.message = message
        failures = []
    }

    init(failures: [CoverageReplayPromptFailure]) {
        message = "Night of the Zealot coverage replay found \(failures.count) failure(s)"
        self.failures = failures
    }

    var description: String {
        guard !failures.isEmpty else { return message }
        let shown = failures.prefix(20).map(\.description).joined(separator: "\n")
        let remaining = failures.count > 20 ? "\n... \(failures.count - 20) more" : ""
        return "\(message):\n\(shown)\(remaining)"
    }
}
