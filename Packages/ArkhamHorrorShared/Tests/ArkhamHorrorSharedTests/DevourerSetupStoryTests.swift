@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("The Devourer Below setup story")
// swiftlint:disable:next type_body_length
struct DevourerSetupStoryTests {
    private static let fixtureName = "devourer-setup-read-agnes-q3"
    private static let fixtureSubdirectory = "Fixtures/LiveNightOfTheZealotPlaythrough"

    @Test("Captured q3 raw Read and v2 presentation bind to the same setup passage")
    func capturedReadPromptBinds() throws {
        let sample = try Self.capturedSample()
        #expect(sample.traceLine == 769)
        #expect(sample.scenario == "c01142")
        #expect(
            sample.statusMessage == "This server publishes no usable story text for this passage."
        )

        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: ContractJSON.encode(sample.rawQuestion)
        )
        let question = try #require(payload.supportedQuestion)
        #expect(question.kind == .read)
        #expect(question.choices.map(\.index) == [0])

        let presentation = try ContractJSON.decode(
            QuestionPresentation.self,
            from: ContractJSON.encode(sample.questionPresentation)
        )
        let bound = try presentation.bind(
            to: payload.rawValue,
            expectedQuestionVersion: sample.questionVersion
        )
        #expect(bound.presentation.questionKind == .read)
        #expect(bound.presentation.readChoiceKind == .basic)
        #expect(bound.presentation.flavorText?.body == [sample.rawFlavorBody])
    }

    @Test("Captured setup renders catalog entries and preserves web-style entry modifiers")
    func capturedSetupRendersFromCatalogWithUnsupportedEntryFallback() async throws {
        let sample = try Self.capturedSample()
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: ContractJSON.encode(sample.rawQuestion)
        )
        let story = try #require(payload.supportedQuestion?.story)
        let resolver = try await Self.catalogResolver(assetSource: .hosted)
        let resolution = StoryNarrativeLocalization.resolve(
            story.flavorText,
            resolver: resolver,
            catalogUnavailability: nil
        )
        let resolved = try #require(resolution.story)
        #expect(resolved.title == "Setup")
        #expect(resolved.degradedReason == .unsupportedEntry)

        guard case let .list(items)? = resolved.body.first else {
            Issue.record("Expected the captured setup passage to stay a list")
            return
        }
        #expect(items.count == 8)

        guard case let .nodes(gatherNodes) = items[0].entry else {
            Issue.record("Expected gatherSets to render from catalog nodes")
            return
        }
        #expect(gatherNodes.first == .text("Gather synthetic encounter sets:"))
        let gatherReferences = gatherNodes.flatMap(Self.encounterSetReferences)
        #expect(gatherReferences.map(\.assetPath) == [
            "encounter-sets/the-devourer-below.png",
            "encounter-sets/ancient-evils.png",
        ])

        guard case let .modified(invalidModifiers, invalidEntry) = items[4].nested[0].entry else {
            Issue.record("Expected invalid cultist count entry to remain modified")
            return
        }
        #expect(invalidModifiers == [.invalidEntry])
        #expect(invalidEntry == .nodes([.text("No synthetic changes.")]))

        guard case let .modified(validModifiers, validEntry) = items[4].nested[3].entry else {
            Issue.record("Expected valid cultist count entry to remain modified")
            return
        }
        #expect(validModifiers == [.validEntry])
        #expect(validEntry == .nodes([.text("Add synthetic doom for five or six names.")]))

        #expect(items[5].entry == .text("addToken (token: elderThing)"))
        let prompt = Self.prompt(payload: payload, resolution: resolution)
        #expect(prompt.canSubmit)
        #expect(prompt.statusMessage == nil)
    }

    @Test("Missing story image source degrades to text without hiding the setup passage")
    func missingImageSourceKeepsCatalogTextVisible() async throws {
        let sample = try Self.capturedSample()
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: ContractJSON.encode(sample.rawQuestion)
        )
        let story = try #require(payload.supportedQuestion?.story)
        let resolver = try await Self.catalogResolver(assetSource: nil)
        let resolution = StoryNarrativeLocalization.resolve(
            story.flavorText,
            resolver: resolver,
            catalogUnavailability: nil
        )
        let resolved = try #require(resolution.story)
        #expect(resolved.degradedReason == .unsupportedEntry)

        guard case let .list(items)? = resolved.body.first,
              case let .nodes(gatherNodes) = items.first?.entry
        else {
            Issue.record("Expected setup list text to remain visible")
            return
        }
        #expect(gatherNodes.first == .text("Gather synthetic encounter sets:"))
        #expect(gatherNodes.map(\.plainText).joined().contains(
            "The Devourer Below encounter set symbol"
        ))
        #expect(gatherNodes.map(\.plainText).joined().contains(
            "Ancient Evils encounter set symbol"
        ))
        #expect(Self.prompt(payload: payload, resolution: resolution).canSubmit)
    }

    private static func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: fixtureSubdirectory
            )
        )
        return try Data(contentsOf: url)
    }

    private static func capturedSample() throws -> CapturedDevourerSetupSample {
        let root = try ContractJSON.decode(JSONValue.self, from: fixture(fixtureName))
        guard case let .object(object) = root,
              case let .string(investigatorSlug)? = object["investigatorSlug"],
              case let .number(traceLineNumber)? = object["traceLine"],
              let traceLine = traceLineNumber.wholeNumberMagnitude.flatMap(Int.init),
              case let .string(scenario)? = object["scenario"],
              case let .number(questionVersionNumber)? = object["questionVersion"],
              let questionVersion = questionVersionNumber.wholeNumberMagnitude.flatMap(Int.init),
              case let .string(rawQuestionTag)? = object["rawQuestionTag"],
              case let .string(statusMessage)? = object["statusMessage"],
              let rawQuestion = object["rawQuestion"],
              let questionPresentation = object["questionPresentation"]
        else {
            throw TestFailure()
        }
        guard case let .object(rawQuestionObject) = rawQuestion,
              case let .object(flavorText)? = rawQuestionObject["flavorText"],
              case let .array(rawBody)? = flavorText["body"],
              let rawFlavorBody = rawBody.first
        else {
            throw TestFailure()
        }
        return CapturedDevourerSetupSample(
            investigatorSlug: investigatorSlug,
            traceLine: traceLine,
            scenario: scenario,
            questionVersion: questionVersion,
            rawQuestionTag: rawQuestionTag,
            statusMessage: statusMessage,
            rawQuestion: rawQuestion,
            questionPresentation: questionPresentation,
            rawFlavorBody: rawFlavorBody
        )
    }

    private static func catalogResolver(
        assetSource: AssetSourceNamespace?
    ) async throws -> LocaleCatalogResolver {
        let snapshot = try await catalogDocuments().loadSnapshot()
        return LocaleCatalogResolver(snapshot: snapshot, assetSource: assetSource)
    }

    private static func catalogDocuments() throws -> SyntheticLocaleCatalogDocuments {
        let entries = [
            "addToken",
            "nightOfTheZealot.theDevourerBelow.setup.cultistsWhoGotAway.fiveOrSixNames",
            "nightOfTheZealot.theDevourerBelow.setup.cultistsWhoGotAway.instructions",
            "nightOfTheZealot.theDevourerBelow.setup.cultistsWhoGotAway.oneOrTwoNames",
            "nightOfTheZealot.theDevourerBelow.setup.cultistsWhoGotAway.threeOrFourNames",
            "nightOfTheZealot.theDevourerBelow.setup.cultistsWhoGotAway.zeroNames",
            "nightOfTheZealot.theDevourerBelow.setup.gatherSets",
            "nightOfTheZealot.theDevourerBelow.setup.ghoulPriest",
            "nightOfTheZealot.theDevourerBelow.setup.pastMidnight",
            "nightOfTheZealot.theDevourerBelow.setup.placeLocations",
            "nightOfTheZealot.theDevourerBelow.setup.randomSet",
            "nightOfTheZealot.theDevourerBelow.setup.setOutOfPlay",
        ]
        return try SyntheticLocaleCatalogDocuments.make(
            entryKeys: entries,
            unsupportedKeys: 1,
            chunkEntries: Self.catalogEntriesJSON
        )
    }

    /// Synthetic prose under the production keys. The captured prompt bytes provide the
    /// scenario structure; the catalog text here only proves that Apple renders server-
    /// supplied catalog nodes and never hard-codes scenario wording.
    private static let catalogEntriesJSON = #"""
    {
      "addToken": {
        "form": "unsupported",
        "reason": "unusable-variable-type",
        "detail": "token is unknown for a text slot"
      },
      "nightOfTheZealot.theDevourerBelow.setup.gatherSets": {
        "form": "message",
        "nodes": [
          {"type": "text", "value": "Gather synthetic encounter sets:"},
          {"type": "group", "styles": ["encounter-sets"], "children": [
            {
              "type": "image",
              "role": "encounterSet",
              "assetPath": "encounter-sets/the-devourer-below.png",
              "styles": []
            },
            {
              "type": "image",
              "role": "encounterSet",
              "assetPath": "encounter-sets/ancient-evils.png",
              "styles": []
            }
          ]}
        ],
        "variables": []
      },
      "nightOfTheZealot.theDevourerBelow.setup.placeLocations": {
        "form": "message",
        "nodes": [{"type": "text", "value": "Place synthetic locations."}],
        "variables": []
      },
      "nightOfTheZealot.theDevourerBelow.setup.setOutOfPlay": {
        "form": "message",
        "nodes": [{"type": "text", "value": "Set synthetic cards aside."}],
        "variables": []
      },
      "nightOfTheZealot.theDevourerBelow.setup.randomSet": {
        "form": "message",
        "nodes": [
          {"type": "text", "value": "Choose one synthetic set:"},
          {"type": "group", "styles": ["encounter-sets"], "children": [
            {
              "type": "image",
              "role": "encounterSet",
              "assetPath": "encounter-sets/agents-of-yog.png",
              "styles": []
            }
          ]}
        ],
        "variables": []
      },
      "nightOfTheZealot.theDevourerBelow.setup.cultistsWhoGotAway.instructions": {
        "form": "message",
        "nodes": [{"type": "text", "value": "Check synthetic cultist counts."}],
        "variables": []
      },
      "nightOfTheZealot.theDevourerBelow.setup.cultistsWhoGotAway.zeroNames": {
        "form": "message",
        "nodes": [{"type": "text", "value": "No synthetic changes."}],
        "variables": []
      },
      "nightOfTheZealot.theDevourerBelow.setup.cultistsWhoGotAway.oneOrTwoNames": {
        "form": "message",
        "nodes": [{"type": "text", "value": "Add synthetic doom for one or two names."}],
        "variables": []
      },
      "nightOfTheZealot.theDevourerBelow.setup.cultistsWhoGotAway.threeOrFourNames": {
        "form": "message",
        "nodes": [{"type": "text", "value": "Add synthetic doom for three or four names."}],
        "variables": []
      },
      "nightOfTheZealot.theDevourerBelow.setup.cultistsWhoGotAway.fiveOrSixNames": {
        "form": "message",
        "nodes": [{"type": "text", "value": "Add synthetic doom for five or six names."}],
        "variables": []
      },
      "nightOfTheZealot.theDevourerBelow.setup.pastMidnight": {
        "form": "message",
        "nodes": [{"type": "text", "value": "Check synthetic midnight log."}],
        "variables": []
      },
      "nightOfTheZealot.theDevourerBelow.setup.ghoulPriest": {
        "form": "message",
        "nodes": [{"type": "text", "value": "Check synthetic priest log."}],
        "variables": []
      }
    }
    """#

    private static func prompt(
        payload: BasicChoiceQuestionPayload,
        resolution: StoryResolution
    ) -> BasicChoicePromptPresentation {
        BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: 3,
                rawQuestion: payload.rawValue,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            storyResolution: resolution,
            choiceLabelResolutions: [0: .resolved("Continue")],
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    private static func encounterSetReferences(_ node: StoryNode) -> [StoryAssetReference] {
        switch node {
        case let .image(reference) where reference.role == .encounterSet:
            [reference]
        case let .group(children):
            children.flatMap(encounterSetReferences)
        default:
            []
        }
    }
}

private struct CapturedDevourerSetupSample {
    let investigatorSlug: String
    let traceLine: Int
    let scenario: String
    let questionVersion: Int
    let rawQuestionTag: String
    let statusMessage: String
    let rawQuestion: JSONValue
    let questionPresentation: JSONValue
    let rawFlavorBody: JSONValue
}
