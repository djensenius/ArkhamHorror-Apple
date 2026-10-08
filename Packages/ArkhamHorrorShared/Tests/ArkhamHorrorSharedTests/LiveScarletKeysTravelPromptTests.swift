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
        let model = try await Self.productionLabelModel(for: fixture)
        let prompt = try Self.prompt(for: fixture, labelModel: model)
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let travelPrompt = try #require(prompt.scarletKeysTravelPrompt)
        let firstAction = try #require(travelPrompt.actions.first { $0.isActionable })

        #expect(prompt.isRenderableQuestion)
        #expect(prompt.canSubmit)
        #expect(prompt.readOnlyReason == nil)
        #expect(travelPrompt.currentLocationID == fixture.expectedCurrentLocationID)
        #expect(travelPrompt.travelTimeLabel == "Travel time")
        #expect(travelPrompt.locations.count == 36)
        #expect(travelPrompt.locations.first?.id == "Alexandria")
        #expect(travelPrompt.locations.first?.title == "Alexandria")
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

    @Test("Apple-only Scarlet Keys travel strings exist in English and German bundles")
    func appleOnlyStringsResolveFromModuleBundle() throws {
        let keys = [
            "scarletKeysTravel.instructions",
            "scarletKeysTravel.currentLocation",
            "scarletKeysTravel.locationTextUnavailable",
            "scarletKeysTravel.actionTextUnavailable",
            "scarletKeysTravel.action.hint",
        ]
        #expect(try localizedModuleString(
            "scarletKeysTravel.instructions",
            fallback: "__missing__",
            locale: "en"
        ) == "Choose a destination on the world map.")
        for locale in ["en", "de"] {
            let strings = try localizableStrings(locale: locale)
            for key in keys {
                #expect(strings.contains("\"\(key)\" ="))
            }
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

    private static func productionLabelModel(
        for fixture: ScarletKeysEmbarkFixture
    ) async throws -> AppModel {
        var entries = [
            "scarletKeys.travelTime": "Travel time",
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
        let url = try #require(Bundle.module.url(
            forResource: "roland-c09501-q145-embark-world-map",
            withExtension: "json",
            subdirectory: "Fixtures/LiveScarletKeysPlaythrough"
        ))
        return try ContractJSON.decode(
            ScarletKeysEmbarkFixture.self,
            from: Data(contentsOf: url)
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
