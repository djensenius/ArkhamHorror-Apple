// swiftlint:disable file_length
@testable import ArkhamHorrorShared
import Foundation
import Testing

private enum NightOfTheZealotCoverageEnvironmentKey {
    static let recordingsDirectory = "ARKHAM_NOTZ_COVERAGE_DIR"
}

private struct NightOfTheZealotPreferredLanguages: PreferredLanguagesProviding {
    let preferredLanguages = ["en"]
}

private func nightOfTheZealotCoverageDirectoryURL() -> URL? {
    guard let rawDirectory = ProcessInfo.processInfo.environment[
        NightOfTheZealotCoverageEnvironmentKey.recordingsDirectory
    ], !rawDirectory.isEmpty else {
        return nil
    }
    return URL(fileURLWithPath: rawDirectory, isDirectory: true)
}

@MainActor
@Suite("Night of the Zealot coverage replay")
struct NightOfTheZealotCoverageReplayTests {
    @Test(
        "Replay coverage JSONL prompts through AppModel",
        .enabled(if: nightOfTheZealotCoverageDirectoryURL() != nil)
    )
    func replayCoverageJSONLPrompts() async throws {
        let directory = try #require(nightOfTheZealotCoverageDirectoryURL())
        try await run(recordings: CoverageRecordingLoader.load(directory: directory))
    }

    @Test("Replay smoke JSONL fixture through the coverage harness")
    func replaySmokeJSONLFixture() async throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "smoke",
                withExtension: "jsonl",
                subdirectory: "Fixtures/NightOfTheZealotCoverageReplay"
            )
        )
        try await run(recordings: CoverageRecordingLoader.load(file: url))
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
            for value in object.values {
                collectLocalizationKeys(from: value, into: &keys)
            }
        }
    }

    private func insertLocalizationKey(_ raw: String, into keys: inout Set<String>) {
        let key = raw.hasPrefix("$") ? String(raw.dropFirst()) : raw
        guard !key.isEmpty, key.contains(".") || raw.hasPrefix("$") else { return }
        keys.insert(key)
    }
}

@MainActor
private struct CoverageReplaySession {
    let model: AppModel
    let connection: FakeGameSocketConnection
    let service: ScriptedGameLifecycleService
    let gameID: GameID
    let baseEnvelopeData: Data
    let deck: Deck

    static func start(
        first: CoverageRecording,
        baseEnvelopeData: Data,
        catalogDocuments: SyntheticLocaleCatalogDocuments,
        deck: Deck
    ) async throws -> CoverageReplaySession {
        let (model, fakes) = makeModel(catalogDocuments: catalogDocuments)
        await model.flowTask?.value
        await model.localeCatalogTask?.value
        let envelope = try CoverageEnvelopeBuilder.envelope(
            for: first.record,
            baseEnvelopeData: baseEnvelopeData
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
            gameID: envelope.game.id,
            baseEnvelopeData: baseEnvelopeData,
            deck: deck
        )
    }

    func show(_ recording: CoverageRecording) async throws {
        let envelope = try CoverageEnvelopeBuilder.envelope(
            for: recording.record,
            baseEnvelopeData: baseEnvelopeData
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
            for (offset, rawLine) in text.split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).enumerated() {
                let line = rawLine.last == "\r" ? rawLine.dropLast() : rawLine[...]
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
        baseEnvelopeData: Data
    ) throws -> GetGameEnvelope {
        var root = try ContractJSON.decode(JSONValue.self, from: baseEnvelopeData)
        guard case var .object(rootObject) = root,
              case var .object(game) = rootObject["game"]
        else { throw TestFailure() }

        rootObject["playerId"] = .string(record.playerID)
        game["activePlayerId"] = .string(record.playerID)
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
        "\(record.fileName):\(record.lineNumber) scenario=\(record.record.scenarioKey) " +
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
