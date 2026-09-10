@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("Story catalog images and actionability")
struct StoryCatalogImageTests {
    /// Production filenames from the web client's English Gathering scenario locale.
    /// Prose is synthetic; governed fixture checksums and official artwork remain untouched.
    static let gatheringSets = [
        "the-gathering", "rats", "ghouls", "striking-fear", "ancient-evils", "chilling-cold",
    ]
    static let gatheringKey = "nightOfTheZealot.theGathering.setup.gatherSets"

    static func documents(
        lastPath: String = "encounter-sets/chilling-cold.png"
    ) throws -> SyntheticLocaleCatalogDocuments {
        let paths = gatheringSets.dropLast().map { "encounter-sets/\($0).png" } + [lastPath]
        let nodes: [[String: Any]] = [
            ["type": "text", "value": "Collect these encounter sets: "],
        ] + paths.map { [
            "type": "image", "role": "encounterSet", "assetPath": $0, "styles": [],
        ] } + [["type": "text", "value": " Then continue."]]
        let entries: [String: Any] = [
            "setup": [
                "form": "message",
                "nodes": [["type": "text", "value": "Setup"]],
                "variables": [],
            ],
            gatheringKey: ["form": "message", "nodes": nodes, "variables": []],
            "nightOfTheZealot.theGathering.setup.placeLocations":
                [
                    "form": "message",
                    "nodes": [["type": "text", "value": "Place locations."]],
                    "variables": [],
                ],
            "nightOfTheZealot.theGathering.setup.setOutOfPlay":
                [
                    "form": "message",
                    "nodes": [["type": "text", "value": "Set aside cards."]],
                    "variables": [],
                ],
            "shuffleRemainder":
                [
                    "form": "message",
                    "nodes": [["type": "text", "value": "Shuffle."]],
                    "variables": [],
                ],
        ]
        let data = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
        let text = try #require(String(data: data, encoding: .utf8))
        return try SyntheticLocaleCatalogDocuments.make(
            entryKeys: entries.keys.sorted(), chunkEntries: text
        )
    }

    static func prompt(
        resolver: LocaleCatalogResolver,
        includingImages: Bool = true,
        catalogRetry: BasicChoiceCatalogRetryPresentation? = nil
    ) throws -> BasicChoicePromptPresentation {
        let fixture = try ReadStoryQuestionTests().fixture("question-read")
        let text = try #require(String(data: fixture, encoding: .utf8))
        let questionText = includingImages ? text
            : text.replacingOccurrences(of: gatheringKey, with: "setup")
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: Data(questionText.utf8)
        )
        let question = try #require(payload.supportedQuestion)
        let story = try #require(question.story)
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(), ownerID: BoardTestFixtures.playerID(),
                questionVersion: 1, rawQuestion: payload.rawValue,
                sessionAttemptID: nil, connectionID: nil
            ),
            question: payload.state,
            storyResolution: StoryNarrativeLocalization.resolve(
                story.flavorText, resolver: resolver, catalogUnavailability: nil
            ),
            readOnlyReason: nil, actionPhase: nil, actionChoiceIndex: nil, serverFeedback: nil,
            catalogRetry: catalogRetry
        )
    }

    @Test("Gathering's six real references resolve and its production Read Continue dispatches")
    func gatheringIsActionable() async throws {
        let snapshot = try await Self.documents().loadSnapshot()
        let resolver = LocaleCatalogResolver(snapshot: snapshot, assetSource: .hosted)
        let nodes = try resolver.render(key: Self.gatheringKey, variables: .object([:])).get()
        #expect(nodes.first == .text("Collect these encounter sets: "))
        #expect(nodes.last == .text(" Then continue."))
        let references = nodes.compactMap { node -> StoryAssetReference? in
            guard case let .image(reference) = node else { return nil }
            return reference
        }
        #expect(references.map(\.assetPath) == Self.gatheringSets
            .map { "encounter-sets/\($0).png" })
        #expect(references.allSatisfy { $0.assetKey != nil })
        let prompt = try Self.prompt(resolver: resolver)
        #expect(prompt.canSubmit)
        var submitted: [Int] = []
        let controller = BoardCommandController(
            projection: BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot()),
            prompt: prompt, onChoice: { submitted.append($0) }
        )
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.handle(.command(.primaryAction)))
        #expect(submitted == [0])

        try controller.applyPrompt(Self.prompt(resolver: LocaleCatalogResolver(snapshot: snapshot)))
        #expect(!controller.handle(.command(.jumpToActivePrompt)))
        #expect(!controller.activatePromptChoice(0))
        #expect(submitted == [0])
    }

    @Test(
        "One unsafe or unsupported reference rejects the complete story and Continue",
        arguments: [
            "encounter-sets/chilling-cold.svg", "encounter-sets//chilling-cold.png",
            "private/chilling-cold.png",
        ]
    )
    func unrepresentableReferenceDisablesStory(_ path: String) async throws {
        let snapshot = try await Self.documents(lastPath: path).loadSnapshot()
        let resolver = LocaleCatalogResolver(snapshot: snapshot, assetSource: .hosted)
        #expect(resolver
            .render(key: Self.gatheringKey, variables: .object([:])) == .failure(.unsupportedEntry))
        let prompt = try Self.prompt(resolver: resolver)
        #expect(!prompt.canSubmit)
        let controller = BoardCommandController(
            projection: BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot()),
            prompt: prompt
        )
        #expect(!controller.activatePromptChoice(0))
    }

    @Test("Malformed and unknown-role catalog nodes never reach native presentation", arguments: [
        ("encounterSet", "encounter-sets/../rats.png"),
        ("encounterSet", "https://evil.test/rats.png"),
        ("arbitrary", "encounter-sets/rats.png"),
    ])
    func invalidCatalogNode(role: String, path: String) {
        let value: JSONValue = .object([
            "type": .string("image"), "role": .string(role), "assetPath": .string(path),
            "styles": .array([]),
        ])
        #expect(LocaleCatalogNode.decode(value, depth: 0) == nil)
    }
}
