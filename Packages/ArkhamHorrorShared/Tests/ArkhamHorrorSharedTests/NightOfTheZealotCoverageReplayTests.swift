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

@MainActor
@Suite("Night of the Zealot coverage replay")
struct NightOfTheZealotCoverageReplayTests {
    @Test("Replay coverage JSONL prompts through AppModel")
    func replayCoverageJSONLPrompts() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawDirectory = environment[
            NightOfTheZealotCoverageEnvironmentKey.recordingsDirectory
        ], !rawDirectory.isEmpty else {
            return
        }

        let recordings = try CoverageRecordingLoader.load(
            directory: URL(fileURLWithPath: rawDirectory, isDirectory: true)
        )
        let catalogDocuments = try makeSyntheticCatalog(for: recordings.records)
        let baseEnvelopeData = try fixtureData(named: "get-game")
        var failures: [CoverageReplayPromptFailure] = []

        for group in recordings.groupsByFile() {
            guard let first = group.records.first else { continue }
            let replay = try await CoverageReplaySession.start(
                first: first,
                baseEnvelopeData: baseEnvelopeData,
                catalogDocuments: catalogDocuments
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
    let gameID: GameID
    let baseEnvelopeData: Data

    static func start(
        first: CoverageRecording,
        baseEnvelopeData: Data,
        catalogDocuments: SyntheticLocaleCatalogDocuments
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
            gameID: envelope.game.id,
            baseEnvelopeData: baseEnvelopeData
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

        var records: [CoverageRecording] = []
        for url in urls {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (offset, line) in text.split(separator: "\n").enumerated() {
                let data = Data(line.utf8)
                try records.append(CoverageRecording(
                    fileName: url.lastPathComponent,
                    lineNumber: offset + 1,
                    record: ContractJSON.decode(CoverageRecord.self, from: data)
                ))
            }
        }
        guard !records.isEmpty else {
            throw CoverageReplayFailure(message: "Coverage JSONL directory contained no records")
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
