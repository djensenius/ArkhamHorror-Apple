@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Semantic movement-entry question presentation v1")
struct QuestionPresentationMovementEntryTests {
    @Test("Q36 binds exact Cellar and Attic movement descriptors")
    func gatheringMovementBinds() throws {
        let presentation = try presentationFixture(
            "question-presentation-gathering-movement"
        )
        #expect(presentation.questionVersion == 36)
        #expect(presentation.questionKind == .playerWindowChooseOne)
        #expect(presentation.choiceCount == 12)

        let cellar = try #require(
            presentation.choices.first { $0.sourceIndex == 9 }
        )
        assertMovementChoice(
            cellar,
            sourceIndex: 9,
            cardCode: "c01114",
            locationID: "a3497b9f-796b-406d-aeb4-9b96fa9f4905"
        )
        let attic = try #require(
            presentation.choices.first { $0.sourceIndex == 10 }
        )
        assertMovementChoice(
            attic,
            sourceIndex: 10,
            cardCode: "c01113",
            locationID: "dbaa2d2e-4ceb-44b2-a554-e5fa370e7882"
        )

        let binding = try presentation.bind(
            to: rawFixture("question-gathering-movement"),
            expectedQuestionVersion: 36
        )
        #expect(binding.descriptor(forSourceIndex: 9) == cellar)
        #expect(binding.descriptor(forSourceIndex: 10) == attic)
        #expect(binding.rawChoice(at: 9) != nil)
        #expect(binding.rawChoice(at: 10) != nil)
        #expect(
            try ContractJSON.decode(
                QuestionPresentation.self,
                from: ContractJSON.encode(presentation)
            ) == presentation
        )
    }

    @Test("Q37 binds exact Cellar and Attic forced abilities")
    func gatheringForcedAbilitiesBind() throws {
        let cellar = try presentationFixture(
            "question-presentation-gathering-cellar-entry-forced"
        )
        let cellarChoice = try #require(cellar.choices.first)
        assertForcedChoice(
            cellarChoice,
            cardCode: "c01114",
            locationID: "a3497b9f-796b-406d-aeb4-9b96fa9f4905"
        )
        #expect(
            try cellar.bind(
                to: rawFixture("question-gathering-cellar-entry-forced"),
                expectedQuestionVersion: 37
            ).descriptor(forSourceIndex: 0) == cellarChoice
        )

        let attic = try presentationFixture(
            "question-presentation-gathering-attic-entry-forced"
        )
        let atticChoice = try #require(attic.choices.first)
        assertForcedChoice(
            atticChoice,
            cardCode: "c01113",
            locationID: "dbaa2d2e-4ceb-44b2-a554-e5fa370e7882"
        )
        #expect(
            try attic.bind(
                to: rawFixture("question-gathering-attic-entry-forced"),
                expectedQuestionVersion: 37
            ).descriptor(forSourceIndex: 0) == atticChoice
        )
    }

    @Test("Q38 binds exact Cellar damage and Attic horror assignments")
    func gatheringAssignmentsBind() throws {
        let cellar = try presentationFixture(
            "question-presentation-gathering-cellar-damage-assignment"
        )
        let cellarChoice = try #require(cellar.choices.first)
        assertAssignmentChoice(cellarChoice, kind: .assignDamage)
        #expect(
            try cellar.bind(
                to: rawFixture("question-gathering-cellar-damage-assignment"),
                expectedQuestionVersion: 38
            ).descriptor(forSourceIndex: 0) == cellarChoice
        )

        let attic = try presentationFixture(
            "question-presentation-gathering-attic-horror-assignment"
        )
        let atticChoice = try #require(attic.choices.first)
        assertAssignmentChoice(atticChoice, kind: .assignHorror)
        #expect(
            try attic.bind(
                to: rawFixture("question-gathering-attic-horror-assignment"),
                expectedQuestionVersion: 38
            ).descriptor(forSourceIndex: 0) == atticChoice
        )
    }

    @Test("Q36-Q38 reject well-shaped static semantic drift")
    func gatheringSemanticIdentityDriftFailsClosed() throws {
        let wrongCellarMove = try mutatedChoiceFixture(
            "question-presentation-gathering-movement",
            choiceIndex: 9
        ) { choice in
            guard case var .object(ability)? = choice["ability"] else {
                throw FixtureMutationError.unexpectedShape
            }
            ability["index"] = .number(.integer(105))
            choice["ability"] = .object(ability)
        }
        assertPresentationDecodeFails(wrongCellarMove)

        let wrongAtticForced = try mutatedChoiceFixture(
            "question-presentation-gathering-attic-entry-forced",
            choiceIndex: 0
        ) { choice in
            guard case var .object(ability)? = choice["ability"] else {
                throw FixtureMutationError.unexpectedShape
            }
            ability["index"] = .number(.integer(2))
            choice["ability"] = .object(ability)
        }
        assertPresentationDecodeFails(wrongAtticForced)

        let wrongAssignmentInvestigator = try mutatedChoiceFixture(
            "question-presentation-gathering-cellar-damage-assignment",
            choiceIndex: 0
        ) { choice in
            guard case var .object(entity)? = choice["entity"] else {
                throw FixtureMutationError.unexpectedShape
            }
            entity["id"] = .string("c01002")
            choice["entity"] = .object(entity)
        }
        assertPresentationDecodeFails(wrongAssignmentInvestigator)
    }

    private func assertMovementChoice(
        _ choice: QuestionPresentation.Choice,
        sourceIndex: Int,
        cardCode: String,
        locationID: String
    ) {
        #expect(choice.sourceIndex == sourceIndex)
        #expect(choice.kind == .move)
        #expect(choice.actorID == "c01001")
        #expect(choice.entity == .init(kind: .location, id: locationID))
        #expect(
            choice.ability
                == .init(
                    cardCode: cardCode,
                    index: 104,
                    type: .action,
                    actions: [.move],
                    canBeCancelled: true
                )
        )
        #expect(choice.cost == .all([.action(1), .other]))
    }

    private func assertForcedChoice(
        _ choice: QuestionPresentation.Choice,
        cardCode: String,
        locationID: String
    ) {
        #expect(choice.sourceIndex == 0)
        #expect(choice.kind == .resolveForcedAbility)
        #expect(choice.actorID == "c01001")
        #expect(choice.entity == .init(kind: .location, id: locationID))
        #expect(choice.ability?.cardCode == cardCode)
        #expect(choice.ability?.index == 1)
        #expect(choice.ability?.type == .forced)
        #expect(choice.ability?.actions == [])
        #expect(choice.cost == .free)
    }

    private func assertAssignmentChoice(
        _ choice: QuestionPresentation.Choice,
        kind: QuestionPresentation.ChoiceKind
    ) {
        #expect(choice.sourceIndex == 0)
        #expect(choice.kind == kind)
        #expect(choice.entity == .init(kind: .investigator, id: "c01001"))
        #expect(choice.actorID == nil)
        #expect(choice.ability == nil)
        #expect(choice.cost == nil)
    }

    private func assertPresentationDecodeFails(_ data: Data) {
        #expect(throws: DecodingError.self) {
            try ContractJSON.decode(QuestionPresentation.self, from: data)
        }
    }

    private func presentationFixture(_ name: String) throws -> QuestionPresentation {
        try ContractJSON.decode(QuestionPresentation.self, from: fixture(name))
    }

    private func rawFixture(_ name: String) throws -> JSONValue {
        try ContractJSON.decode(JSONValue.self, from: fixture(name))
    }

    private func mutatedChoiceFixture(
        _ name: String,
        choiceIndex: Int,
        mutate: (inout [String: JSONValue]) throws -> Void
    ) throws -> Data {
        let value = try ContractJSON.decode(JSONValue.self, from: fixture(name))
        guard case var .object(root) = value,
              case var .array(choices)? = root["choices"],
              choices.indices.contains(choiceIndex),
              case var .object(choice) = choices[choiceIndex]
        else {
            throw FixtureMutationError.unexpectedShape
        }
        try mutate(&choice)
        choices[choiceIndex] = .object(choice)
        root["choices"] = .array(choices)
        return try ContractJSON.encode(JSONValue.object(root))
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

    private enum FixtureMutationError: Error {
        case unexpectedShape
    }
}
