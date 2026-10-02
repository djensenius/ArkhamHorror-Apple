@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Treachery forced-ability raw binding")
struct TreacheryForcedAbilityBindingTests {
    @Test("The descriptor binds every projected authority field")
    func bindsCanonicalDescriptor() throws {
        let presentation = try presentationFixture()
        let binding = try presentation.bind(
            to: rawFixture(),
            expectedQuestionVersion: 68
        )

        #expect(
            binding.descriptor(forSourceIndex: 0) ==
                QuestionPresentation.Choice(
                    sourceIndex: 0,
                    kind: .resolveForcedAbility,
                    actorID: "c01001",
                    entity: .init(
                        kind: .treachery,
                        id: treacheryForcedAbilityFixtureID
                    ),
                    label: nil,
                    ability: .init(
                        cardCode: "c01007",
                        index: 2,
                        type: .forced,
                        actions: [],
                        canBeCancelled: true
                    ),
                    cost: .free
                )
        )
    }

    @Test("Binding is independent of a scenario's prompt sequence")
    func bindsAtAnotherQuestionVersion() throws {
        let rawPresentation = try replacing(
            presentationJSON(),
            at: "/questionVersion",
            with: .number(.integer(37))
        )
        let presentation = try ContractJSON.decode(
            QuestionPresentation.self,
            from: ContractJSON.encode(rawPresentation)
        )

        let binding = try presentation.bind(
            to: rawFixture(),
            expectedQuestionVersion: 37
        )

        #expect(
            binding.descriptor(forSourceIndex: 0)?.kind ==
                .resolveForcedAbility
        )
    }

    @Test(
        "Raw authority drift does not gate generic treachery prompts",
        arguments: [
            ("/choices/0/investigatorId", JSONValue.string("c02001")),
            (
                "/choices/0/ability/source/contents",
                JSONValue.string("11111111-1111-4111-8111-111111111111")
            ),
            (
                "/choices/0/ability/requestor/contents",
                JSONValue.string("11111111-1111-4111-8111-111111111111")
            ),
            ("/choices/0/ability/cardCode", JSONValue.string("c01165")),
            ("/choices/0/ability/index", JSONValue.number(.integer(1))),
            (
                "/choices/0/ability/type/tag",
                JSONValue.string("ReactionAbility")
            ),
            ("/choices/0/ability/canBeCancelled", JSONValue.bool(false)),
            (
                "/choices/0/ability/target",
                JSONValue.object([
                    "tag": .string("TreacheryTarget"),
                    "contents": .string(treacheryForcedAbilityFixtureID),
                ])
            ),
            (
                "/choices/0/ability/additionalCosts",
                JSONValue.array([
                    .object([
                        "tag": .string("ResourceCost"),
                        "contents": .number(.integer(1)),
                    ]),
                ])
            ),
        ]
    )
    func rawAuthorityDriftDoesNotGateGenericTreacheryPrompt(
        pointer: String,
        replacement: JSONValue
    ) throws {
        let raw = try replacing(
            rawFixture(),
            at: pointer,
            with: replacement
        )
        let binding = try presentationFixture().bind(
            to: raw,
            expectedQuestionVersion: 68
        )
        try assertGenericTreacheryPromptRemainsActionable(binding)
    }

    @Test(
        "Presentation authority drift remains a generic treachery prompt",
        arguments: [
            ("/choices/0/actorId", JSONValue.string("c02001")),
            (
                "/choices/0/entity/id",
                JSONValue.string("11111111-1111-4111-8111-111111111111")
            ),
            ("/choices/0/ability/cardCode", JSONValue.string("c01165")),
            ("/choices/0/ability/index", JSONValue.number(.integer(1))),
            (
                "/choices/0/ability/type",
                JSONValue.string("reaction")
            ),
            ("/choices/0/ability/canBeCancelled", JSONValue.bool(false)),
            (
                "/choices/0/cost",
                JSONValue.object([
                    "kind": .string("action"),
                    "amount": .number(.integer(1)),
                ])
            ),
        ]
    )
    func presentationAuthorityDriftRemainsGenericTreacheryPrompt(
        pointer: String,
        replacement: JSONValue
    ) throws {
        let rawPresentation = try replacing(
            presentationJSON(),
            at: pointer,
            with: replacement
        )
        let presentation = try ContractJSON.decode(
            QuestionPresentation.self,
            from: ContractJSON.encode(rawPresentation)
        )
        let binding = try presentation.bind(
            to: rawFixture(),
            expectedQuestionVersion: 68
        )
        try assertGenericTreacheryPromptRemainsActionable(binding)
    }

    @Test(
        "Presentation drift binds generically independent of scenario step",
        arguments: [37, 68]
    )
    func presentationDriftBindsGenericallyAtGatheringRangeAndLaterVersions(
        questionVersion: Int
    ) throws {
        var rawPresentation = try replacing(
            presentationJSON(),
            at: "/choices/0/actorId",
            with: .string("c02001")
        )
        rawPresentation = try replacing(
            rawPresentation,
            at: "/questionVersion",
            with: .number(.integer(Int64(questionVersion)))
        )
        let presentation = try ContractJSON.decode(
            QuestionPresentation.self,
            from: ContractJSON.encode(rawPresentation)
        )
        let binding = try presentation.bind(
            to: rawFixture(),
            expectedQuestionVersion: questionVersion
        )
        try assertGenericTreacheryPromptRemainsActionable(binding)
        #expect(binding.descriptor(forSourceIndex: 0)?.actorID == "c02001")
    }

    private func assertGenericTreacheryPromptRemainsActionable(
        _ binding: BoundQuestionPresentation
    ) throws {
        let descriptor = try #require(binding.descriptor(forSourceIndex: 0))
        #expect(binding.isRenderableInCurrentClient)
        #expect(descriptor.kind == .resolveForcedAbility)
        #expect(descriptor.selectable)
        #expect(binding.canActivateSemanticChoice(descriptor, labelResolution: nil))
    }

    private func replacing(
        _ value: JSONValue,
        at pointer: String,
        with replacement: JSONValue
    ) throws -> JSONValue {
        try EnemyAttackFixtures.applying(
            operation: "replace",
            path: pointer.split(separator: "/"),
            replacement: replacement,
            to: value
        )
    }

    private func rawFixture() throws -> JSONValue {
        try ContractJSON.decode(
            JSONValue.self,
            from: fixture("question-treachery-forced-ability")
        )
    }

    private func presentationFixture() throws -> QuestionPresentation {
        try ContractJSON.decode(
            QuestionPresentation.self,
            from: fixture("question-presentation-treachery-forced-ability")
        )
    }

    private func presentationJSON() throws -> JSONValue {
        try ContractJSON.decode(
            JSONValue.self,
            from: fixture("question-presentation-treachery-forced-ability")
        )
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try Data(contentsOf: url)
    }
}

let treacheryForcedAbilityFixtureID =
    "fef723b4-ae76-4183-9441-b4f3cb8b1eb5"
