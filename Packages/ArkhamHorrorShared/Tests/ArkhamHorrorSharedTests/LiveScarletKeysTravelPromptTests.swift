@testable import ArkhamHorrorShared
import Foundation
import Testing

private struct ScarletKeysPreferredLanguages: PreferredLanguagesProviding {
    let preferredLanguages: [String]
}

@MainActor
@Suite("Live Scarlet Keys travel prompt")
struct LiveScarletKeysTravelPromptTests {
    @Test("Captured embark world-map prompt renders and encodes CampaignSpecificAnswer bytes")
    func capturedEmbarkPromptRendersAndEncodesTravelAnswer() async throws {
        let fixture = try Self.fixture()
        let model = try await Self.syntheticLocationLabelModel(for: fixture)
        let prompt = try Self.prompt(for: fixture, labelModel: model)
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let travelPrompt = try #require(prompt.scarletKeysTravelPrompt)
        let firstAction = try #require(travelPrompt.actions.first { $0.isActionable })

        #expect(prompt.isRenderableQuestion)
        #expect(prompt.canSubmit)
        #expect(prompt.readOnlyReason == nil)
        let currentLocation = try #require(travelPrompt.locations.first { $0.isCurrent })
        let lockedLocation = try #require(travelPrompt.locations.first { $0.id == "HongKong" })

        #expect(travelPrompt.currentLocationID == fixture.expectedCurrentLocationID)
        #expect(travelPrompt.currentLocationTitle == "You are currently here.")
        #expect(travelPrompt.travelTimeLabel == "Travel time")
        #expect(travelPrompt.locations.count == 36)
        #expect(travelPrompt.locations.first?.id == "Alexandria")
        #expect(travelPrompt.locations.first?.title == "Alexandria")
        #expect(currentLocation.id == "London")
        #expect(currentLocation.travelTime == nil)
        #expect(currentLocation.actions.isEmpty)
        #expect(lockedLocation.isLocked)
        #expect(lockedLocation.lockedTitle == "Location locked")
        #expect(
            firstAction.payload
                == .array(fixture.expectedFirstActionPayload.map(JSONValue.string))
        )
        #expect(prompt.supportsCampaignSpecificSubmission(firstAction.payload))

        let encoded = try ContractJSON.encode(CampaignSpecificAnswer(contents: firstAction.payload))
        let wire = try #require(String(data: encoded, encoding: .utf8))
        #expect(wire == #"{"contents":["travel","Alexandria"],"tag":"CampaignSpecificAnswer"}"#)

        var submitted: [JSONValue] = []
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            onCampaignSpecific: { submitted.append($0) }
        )
        #expect(controller.coordinator.graph.contains(
            BoardFocusID.promptScarletKeysTravelAction(firstAction)
        ))
        #expect(controller.handle(
            focusID: BoardFocusID.promptScarletKeysTravelAction(firstAction),
            .command(.primaryAction)
        ))
        #expect(submitted == [firstAction.payload])
    }

    @Test("Expedited tickets use displayed travel time for green and non-green locations")
    func expeditedTicketsUseDisplayedTravelTime() async throws {
        let fixture = try Self.fixture(named: "roland-c09501-q145-embark-world-map-has-ticket")
        let model = try await Self.syntheticLocationLabelModel(for: fixture)
        let prompt = try Self.prompt(for: fixture, labelModel: model)
        let travelPrompt = try #require(prompt.scarletKeysTravelPrompt)
        let arkham = try #require(travelPrompt.locations.first { $0.id == "Arkham" })
        let alexandria = try #require(travelPrompt.locations.first { $0.id == "Alexandria" })
        let venice = try #require(travelPrompt.locations.first { $0.id == "Venice" })

        #expect(arkham.travelTime == 2)
        #expect(arkham.actions.contains { $0.kind == .travelWithTicket && $0.isActionable })
        #expect(alexandria.travelTime == 2)
        #expect(alexandria.actions.contains { $0.kind == .travelWithTicket && $0.isActionable })
        #expect(venice.travelTime == 1)
        #expect(!venice.actions.contains { $0.kind == .travelWithTicket })
    }

    @Test("Green locations with null travel display one time and no ticket")
    func greenLocationWithNullTravelDisplaysOne() async throws {
        let fixture = try Self.fixtureSettingTravel(locationID: "Venice", travel: .null)
        let model = try await Self.syntheticLocationLabelModel(for: fixture)
        let prompt = try Self.prompt(for: fixture, labelModel: model)
        let travelPrompt = try #require(prompt.scarletKeysTravelPrompt)
        let venice = try #require(travelPrompt.locations.first { $0.id == "Venice" })

        #expect(venice.travelTime == 1)
        #expect(!venice.actions.contains { $0.kind == .travelWithTicket })
    }

    @Test("Malformed location entries skip only that location")
    func malformedLocationEntrySkipsOnlyThatEntry() async throws {
        let fixture = try Self.fixtureReplacingLocationEntry(
            locationID: "BermudaTriangle",
            entry: .array([.string("BermudaTriangle")])
        )
        let model = try await Self.syntheticLocationLabelModel(for: fixture)
        let prompt = try Self.prompt(for: fixture, labelModel: model)
        let travelPrompt = try #require(prompt.scarletKeysTravelPrompt)
        let alexandria = try #require(travelPrompt.locations.first { $0.id == "Alexandria" })

        #expect(travelPrompt.locations.count == 35)
        #expect(!travelPrompt.locations.contains { $0.id == "BermudaTriangle" })
        #expect(alexandria.isActionable)
        #expect(try prompt.supportsCampaignSpecificSubmission(#require(alexandria.actions.first).payload))
    }

    @Test("Missing world-map labels keep travel actions unpressable")
    func missingLocationLabelDoesNotExposeRawLocationFallback() async throws {
        let fixture = try Self.fixture()
        let model = try await Self.labelModel(entries: [
            "scarletKeys.travelTime": "Travel time",
            "scarletKeys.travelHere": "Travel here",
            "scarletKeys.travelWithoutStopping": "Travel here without stopping",
            "scarletKeys.travelWithExpeditedTicket": "Travel with Expedited Ticket (1 time)",
        ])
        let prompt = try Self.prompt(for: fixture, labelModel: model)
        let travelPrompt = try #require(prompt.scarletKeysTravelPrompt)
        let firstLocation = try #require(travelPrompt.locations.first)
        let firstAction = try #require(firstLocation.actions.first)
        let focusID = BoardFocusID.promptScarletKeysTravelAction(firstAction)
        var submitted: [JSONValue] = []
        let controller = BoardCommandController(
            projection: BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot()),
            prompt: prompt,
            onCampaignSpecific: { submitted.append($0) }
        )

        #expect(firstLocation.id == "Alexandria")
        #expect(firstLocation.title == nil)
        #expect(firstLocation.isActionable == false)
        #expect(firstAction.title == "Travel here")
        #expect(!firstAction.isActionable)
        #expect(!travelPrompt.actions.contains { $0.locationID == "Alexandria" && $0.isActionable })
        #expect(!prompt.supportsCampaignSpecificSubmission(firstAction.payload))
        #expect(!controller.coordinator.graph.contains(focusID))
        #expect(!controller.handle(focusID: focusID, .command(.primaryAction)))
        #expect(submitted.isEmpty)
    }

    @Test("Finale keeps a travel action on the current single available location")
    func finaleKeepsCurrentLocationTravelAction() async throws {
        let fixture = try Self.fixtureSettingAvailable(["London"])
        let model = try await Self.syntheticLocationLabelModel(for: fixture)
        let prompt = try Self.prompt(for: fixture, labelModel: model)
        let travelPrompt = try #require(prompt.scarletKeysTravelPrompt)
        let london = try #require(travelPrompt.locations.first { $0.id == "London" })
        let action = try #require(london.actions.first)

        #expect(london.isCurrent)
        #expect(london.actions.map(\.kind) == [.travel])
        #expect(prompt.supportsCampaignSpecificSubmission(action.payload))
    }

    @Test("AppModel sends exact Scarlet Keys travel bytes and rejects stale or forged payloads")
    func appModelSendPathSendsExactBytesAndRejectsInvalidPayloads() async throws {
        let fixture = try Self.fixture()
        let model = try await Self.syntheticLocationLabelModel(for: fixture)
        let gameID = GameID(UUID())
        let ownerID = BoardTestFixtures.playerID("000000000001")
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        try Self.installFixturePrompt(
            fixture,
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let payload = JSONValue.array([.string("travel"), .string("Alexandria")])

        #expect(await model.submitCampaignSpecificAnswer(
            prompt.identity,
            contents: payload
        ) == .sentAwaitingSnapshot)
        let sent = try #require(await connection.sentData.first)
        let wire = try #require(String(data: sent, encoding: .utf8))
        #expect(wire == #"{"contents":["travel","Alexandria"],"tag":"CampaignSpecificAnswer"}"#)

        let staleModel = try await Self.syntheticLocationLabelModel(for: fixture)
        let staleConnection = FakeGameSocketConnection()
        try Self.installFixturePrompt(
            fixture,
            on: staleModel,
            gameID: gameID,
            ownerID: ownerID,
            connection: staleConnection
        )
        let stalePrompt = try #require(staleModel.basicChoicePresentation(for: gameID))
        staleModel.liveGameStates[gameID] = .live(
            BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        )
        #expect(await staleModel.submitCampaignSpecificAnswer(
            stalePrompt.identity,
            contents: payload
        ) == .staleQuestion)
        #expect(await staleConnection.sentData.isEmpty)

        for forgedPayload in [
            JSONValue.array([.string("travel"), .string("Atlantis")]),
            JSONValue.array([.string("travel"), .string("HongKong")]),
        ] {
            let forgedModel = try await Self.syntheticLocationLabelModel(for: fixture)
            let forgedConnection = FakeGameSocketConnection()
            let forgedGameID = GameID(UUID())
            try Self.installFixturePrompt(
                fixture,
                on: forgedModel,
                gameID: forgedGameID,
                ownerID: ownerID,
                connection: forgedConnection
            )
            let forgedPrompt = try #require(forgedModel.basicChoicePresentation(
                for: forgedGameID
            ))
            #expect(await forgedModel.submitCampaignSpecificAnswer(
                forgedPrompt.identity,
                contents: forgedPayload
            ) == .unsupportedChoice)
            #expect(await forgedConnection.sentData.isEmpty)
        }
    }

    @Test("Apple-only Scarlet Keys travel strings exist in English and German bundles")
    func appleOnlyStringsResolveFromModuleBundle() throws {
        let keys = [
            "scarletKeysTravel.instructions",
            "scarletKeysTravel.locationTextUnavailable",
            "scarletKeysTravel.actionTextUnavailable",
            "scarletKeysTravel.action.hint",
        ]
        #expect(try localizedModuleString(
            "scarletKeysTravel.instructions",
            fallback: "__missing__",
            locale: "en"
        ) == "Choose a destination on the world map.")
        #expect(try localizedModuleString(
            "scarletKeysTravel.instructions",
            fallback: "__missing__",
            locale: "de"
        ) == "Wähle ein Ziel auf der Weltkarte.")
        for locale in ["en", "de"] {
            let strings = try localizableStrings(locale: locale)
            for key in keys {
                #expect(strings.contains("\"\(key)\" ="))
            }
            #expect(!strings.contains("\"scarletKeysTravel.currentLocation\" ="))
        }
    }

    private static func prompt(
        for fixture: ScarletKeysEmbarkFixture,
        labelModel: AppModel
    ) throws -> BasicChoicePromptPresentation {
        let bound = try fixture.questionPresentation.bind(
            to: fixture.rawQuestion,
            expectedQuestionVersion: fixture.source.questionVersion
        )
        let question = BasicChoiceParser.parseQuestion(fixture.rawQuestion)
        let labelResolutions = labelModel.promptLabelResolutions(
            for: fixture.questionPresentation
        )
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID("000000000001"),
                questionVersion: fixture.source.questionVersion,
                rawQuestion: fixture.rawQuestion,
                questionPresentation: fixture.questionPresentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: question,
            semanticPresentation: bound,
            semanticLocaleIdentifier: "en",
            promptLabelResolutions: labelResolutions,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    private static func syntheticLocationLabelModel(
        for fixture: ScarletKeysEmbarkFixture
    ) async throws -> AppModel {
        var entries = [
            "scarletKeys.travelTime": "Travel time",
            "scarletKeys.youAreCurrentlyHere": "You are currently here.",
            "scarletKeys.locationLocked": "Location locked",
            "scarletKeys.travelHere": "Travel here",
            "scarletKeys.travelWithoutStopping": "Travel here without stopping",
            "scarletKeys.travelWithExpeditedTicket": "Travel with Expedited Ticket (1 time)",
        ]
        let locationIDs = fixture.questionPresentation.value?.objectValue?["locations"]?
            .arrayValue?.compactMap { $0.arrayValue?.first?.stringValue } ?? []
        for locationID in locationIDs {
            entries["theScarletKeys.locations.\(locationID).name"] = splitCamelCase(locationID)
        }
        entries["theScarletKeys.locations.Alexandria.subtitle"] = "Egypt"
        return try await labelModel(entries: entries)
    }

    private static func labelModel(entries: [String: String]) async throws -> AppModel {
        let documents = try SyntheticLocaleCatalogDocuments.make(
            pack: "scarlet-keys-travel",
            entryKeys: entries.keys.sorted(),
            chunkEntries: localeCatalogChunkEntries(entries)
        )
        let model = AppModel(
            profileStore: FakeServerProfileStore(
                profiles: [documents.profile], selectedID: documents.profile.id
            ),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value
        model.sessionState = .signedIn(
            profile: documents.profile,
            compatibility: .modern(capabilities: []),
            user: .sample
        )
        model.localeCatalog = try await documents.loadSnapshot()
        model.localeCatalogRequest = LocaleCatalogRequest(
            profileID: model.selectedProfile.id,
            advertisement: documents.advertisement
        )
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

    private static func splitCamelCase(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            if CharacterSet.uppercaseLetters.contains(scalar), !result.isEmpty {
                result.append(" ")
            }
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    private static func fixture() throws -> ScarletKeysEmbarkFixture {
        try fixture(named: "roland-c09501-q145-embark-world-map")
    }

    private static func fixture(named name: String) throws -> ScarletKeysEmbarkFixture {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/LiveScarletKeysPlaythrough"
        ))
        return try ContractJSON.decode(
            ScarletKeysEmbarkFixture.self,
            from: Data(contentsOf: url)
        )
    }

    private static func fixtureSettingTravel(
        locationID: String,
        travel: JSONValue
    ) throws -> ScarletKeysEmbarkFixture {
        try fixtureMutatingMap(named: "roland-c09501-q145-embark-world-map-has-ticket") { map in
            try map.replacingTravel(locationID: locationID, travel: travel)
        }
    }

    private static func fixtureReplacingLocationEntry(
        locationID: String,
        entry: JSONValue
    ) throws -> ScarletKeysEmbarkFixture {
        try fixtureMutatingMap(named: "roland-c09501-q145-embark-world-map") { map in
            try map.replacingLocationEntry(locationID: locationID, entry: entry)
        }
    }

    private static func fixtureSettingAvailable(
        _ locationIDs: [String]
    ) throws -> ScarletKeysEmbarkFixture {
        try fixtureMutatingMap(named: "roland-c09501-q145-embark-world-map") { map in
            map.replacingAvailable(locationIDs)
        }
    }

    private static func fixtureMutatingMap(
        named name: String,
        transform: (JSONValue) throws -> JSONValue
    ) throws -> ScarletKeysEmbarkFixture {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/LiveScarletKeysPlaythrough"
        ))
        let data = try Data(contentsOf: url)
        let root = try ContractJSON.decode(JSONValue.self, from: data)
        let mutated = try root.replacingScarletKeysEmbarkMap(transform)
        return try ContractJSON.decode(
            ScarletKeysEmbarkFixture.self,
            from: ContractJSON.encode(mutated)
        )
    }

    private static func installFixturePrompt(
        _ fixture: ScarletKeysEmbarkFixture,
        on model: AppModel,
        gameID: GameID,
        ownerID: PlayerID,
        connection: FakeGameSocketConnection
    ) throws {
        let attemptID = UUID()
        model.liveGameStates[gameID] = try .live(projection(for: fixture, ownerID: ownerID))
        model.liveGameParticipantIdentities[gameID] = .participant(ownerID)
        model.liveGameSessions[gameID] = LiveGameSessionHandle(
            attemptID: attemptID,
            task: Task {}
        )
        model.liveGameConnections[gameID] = LiveGameConnectionHandle(
            attemptID: attemptID,
            connectionID: UUID(),
            connection: connection
        )
    }

    private static func projection(
        for fixture: ScarletKeysEmbarkFixture,
        ownerID: PlayerID
    ) throws -> BoardProjection {
        let bound = try fixture.questionPresentation.bind(
            to: fixture.rawQuestion,
            expectedQuestionVersion: fixture.source.questionVersion
        )
        var questions = UUIDKeyedMap<PlayerIDTag, BasicChoiceQuestionPayload>()
        questions[ownerID] = BasicChoiceQuestionPayload(
            rawValue: fixture.rawQuestion,
            state: BasicChoiceParser.parseQuestion(fixture.rawQuestion),
            presentation: bound
        )
        let base = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        return campaignPromptProjection(
            base: base,
            questions: questions,
            counters: counters(base.counters, scenarioSteps: fixture.source.questionVersion)
        )
    }

    private static func counters(
        _ base: BoardCounters,
        scenarioSteps: Int
    ) -> BoardCounters {
        BoardCounters(
            totalDoom: base.totalDoom,
            totalClues: base.totalClues,
            encounterDeckSize: base.encounterDeckSize,
            scenarioSteps: scenarioSteps,
            playerCount: base.playerCount,
            phase: base.phase,
            phaseStepSummary: base.phaseStepSummary,
            gameStateSummary: base.gameStateSummary,
            inSetup: base.inSetup,
            inAction: base.inAction,
            pendingPromptCount: base.pendingPromptCount,
            entityCounters: base.entityCounters
        )
    }

    private func localizedModuleString(
        _ key: String,
        fallback: String,
        locale: String
    ) throws -> String {
        let bundle = try moduleBundle(locale: locale)
        return NSLocalizedString(key, bundle: bundle, value: fallback, comment: "")
    }

    private func moduleBundle(locale: String) throws -> Bundle {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/ArkhamHorrorShared/Localization")
            .appending(path: "\(locale).lproj")
        return try #require(Bundle(url: url))
    }

    private func localizableStrings(locale: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/ArkhamHorrorShared/Localization")
            .appending(path: "\(locale).lproj/Localizable.strings")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private extension JSONValue {
    func replacingScarletKeysEmbarkMap(
        _ transform: (JSONValue) throws -> JSONValue
    ) throws -> JSONValue {
        guard case var .object(root) = self,
              case var .object(rawQuestion) = root["rawQuestion"],
              case var .array(rawContents) = rawQuestion["contents"],
              rawContents.count == 2,
              case var .object(questionPresentation) = root["questionPresentation"],
              let presentationValue = questionPresentation["value"]
        else { throw TestFailure() }
        rawContents[1] = try transform(rawContents[1])
        rawQuestion["contents"] = .array(rawContents)
        root["rawQuestion"] = .object(rawQuestion)
        questionPresentation["value"] = try transform(presentationValue)
        root["questionPresentation"] = .object(questionPresentation)
        return .object(root)
    }

    func replacingTravel(locationID: String, travel: JSONValue) throws -> JSONValue {
        try replacingLocationEntry(locationID: locationID) { originalPair in
            var pair = originalPair
            guard case var .object(detail) = pair[1] else { throw TestFailure() }
            detail["travel"] = travel
            pair[1] = .object(detail)
            return .array(pair)
        }
    }

    func replacingAvailable(_ locationIDs: [String]) -> JSONValue {
        guard case var .object(map) = self else { return self }
        map["available"] = .array(locationIDs.map(JSONValue.string))
        return .object(map)
    }

    func replacingLocationEntry(locationID: String, entry: JSONValue) throws -> JSONValue {
        try replacingLocationEntry(locationID: locationID) { _ in entry }
    }

    func replacingLocationEntry(
        locationID: String,
        with transform: ([JSONValue]) throws -> JSONValue
    ) throws -> JSONValue {
        guard case var .object(map) = self,
              case var .array(locations) = map["locations"]
        else { throw TestFailure() }
        var didReplace = false
        locations = try locations.map { entry in
            guard case let .array(pair) = entry,
                  pair.count == 2,
                  pair.first == .string(locationID)
            else { return entry }
            didReplace = true
            return try transform(pair)
        }
        guard didReplace else { throw TestFailure() }
        map["locations"] = .array(locations)
        return .object(map)
    }
}

private struct ScarletKeysEmbarkFixture: Decodable, Sendable {
    let source: Source
    let expectedCurrentLocationID: String
    let expectedFirstActionPayload: [String]
    let rawQuestion: JSONValue
    let questionPresentation: QuestionPresentation

    struct Source: Decodable, Sendable {
        let questionVersion: Int
    }
}
