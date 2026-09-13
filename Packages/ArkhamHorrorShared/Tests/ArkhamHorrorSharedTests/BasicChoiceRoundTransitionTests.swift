@testable import ArkhamHorrorShared
import Foundation
import Testing

enum RoundTransitionFixtures {
    enum Fixture: String, CaseIterable {
        case forcedAbility = "question-round-end-forced-ability"
        case agendaAdvance = "question-agenda-advance"
        case agendaConsequence = "question-agenda-consequence"
        case agendaHorrorAssignment = "question-agenda-horror-assignment"
    }

    static let investigatorID = BoardTestFixtures.investigatorID("c01001")
    static let agendaID = BoardTestFixtures.agendaID("c01105")
    static let treacheryID = BoardTestFixtures.treacheryID(
        "9e2f9137-ff19-4993-b001-acc24d0d3736"
    )

    static func data(_ fixture: Fixture) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: fixture.rawValue,
            withExtension: "json",
            subdirectory: "Fixtures/Contract"
        ))
        return try Data(contentsOf: url)
    }

    static func value(_ fixture: Fixture) throws -> JSONValue {
        try ContractJSON.decode(JSONValue.self, from: data(fixture))
    }

    static func payload(_ fixture: Fixture) throws -> BasicChoiceQuestionPayload {
        try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: data(fixture)
        )
    }

    static func prompt(
        _ fixture: Fixture,
        questionVersion: Int = 24,
        labelResolutions: [Int: BasicChoiceLabelResolution]? = nil
    ) throws -> BasicChoicePromptPresentation {
        let payload = try payload(fixture)
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID("000000000001"),
                questionVersion: questionVersion,
                rawQuestion: payload.rawValue,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            choiceLabelResolutions: labelResolutions,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    static func projection(
        includeTreachery: Bool = true,
        includeAgenda: Bool = true,
        includeInvestigator: Bool = true
    ) -> BoardProjection {
        let investigators: [InvestigatorID: Investigator] = includeInvestigator
            ? [
                investigatorID: BoardTestFixtures.investigator(
                    id: investigatorID,
                    name: CardName(title: "Roland Banks", subtitle: "The Fed")
                ),
            ]
            : [:]
        let agendas: [AgendaID: Agenda] = includeAgenda
            ? [agendaID: BoardTestFixtures.agenda(id: agendaID)]
            : [:]
        let treacheries: [TreacheryID: JSONValue] = includeTreachery
            ? [treacheryID: .null]
            : [:]
        return BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            investigators: investigators,
            agendas: agendas,
            playerOrder: includeInvestigator ? [investigatorID] : [],
            treacheryValues: treacheries
        ))
    }

    static let resolvedConsequenceLabels: [Int: BasicChoiceLabelResolution] = [
        0: .resolved("The lead investigator takes 2 horror"),
        1: .resolved("Each investigator discards 1 card at random from their hand"),
    ]
}

@MainActor
@Suite("Round and agenda transition choices")
struct BasicChoiceRoundTransitionTests {
    @Test("All four production prompts retain exact semantic identities and payloads")
    func governedPromptsParseLosslessly() throws {
        try assertForcedAbilityPrompt()
        try assertAgendaAdvancePrompt()
        try assertAgendaConsequencePrompt()
        try assertAgendaHorrorAssignmentPrompt()
        try assertFixtureRoundTrips()
    }

    private func assertForcedAbilityPrompt() throws {
        let forcedPayload = try RoundTransitionFixtures.payload(.forcedAbility)
        let forcedQuestion = try #require(forcedPayload.supportedQuestion)
        #expect(forcedQuestion.kind == .windowChooseOne)
        #expect(forcedQuestion.choices.map(\.index) == [0])
        guard case let .resolveForcedAbility(forced) = forcedQuestion.choices[0].content else {
            Issue.record("Expected the governed forced ability")
            return
        }
        #expect(forced.treacheryID == RoundTransitionFixtures.treacheryID)
        #expect(forced.ability.investigatorID == RoundTransitionFixtures.investigatorID)
        #expect(forced.ability.cardCode.rawValue == "c01165")
        #expect(forced.ability.before.isEmpty)
        #expect(forced.ability.messages.isEmpty)
    }

    private func assertAgendaAdvancePrompt() throws {
        let advancePayload = try RoundTransitionFixtures.payload(.agendaAdvance)
        let advanceQuestion = try #require(advancePayload.supportedQuestion)
        #expect(advanceQuestion.kind == .chooseOne)
        guard case let .advanceAgenda(agendaID, messages) =
            advanceQuestion.choices[0].content
        else {
            Issue.record("Expected the governed agenda advancement")
            return
        }
        #expect(agendaID == RoundTransitionFixtures.agendaID)
        #expect(messages.count == 1)
    }

    private func assertAgendaConsequencePrompt() throws {
        let consequencePayload = try RoundTransitionFixtures.payload(.agendaConsequence)
        let consequenceQuestion = try #require(consequencePayload.supportedQuestion)
        #expect(consequenceQuestion.kind == .chooseOne)
        #expect(consequenceQuestion.choices.map(\.index) == [0, 1])
        guard case let .chooseAgendaConsequence(horror) =
            consequenceQuestion.choices[0].content,
            case let .chooseAgendaConsequence(discard) =
            consequenceQuestion.choices[1].content
        else {
            Issue.record("Expected both governed agenda consequences")
            return
        }
        #expect(horror.kind == .takeHorror)
        #expect(horror.agendaID == RoundTransitionFixtures.agendaID)
        #expect(horror.investigatorID == RoundTransitionFixtures.investigatorID)
        #expect(horror.messages.count == 1)
        #expect(discard.kind == .randomDiscard)
        #expect(discard.agendaID == RoundTransitionFixtures.agendaID)
        #expect(discard.investigatorID == nil)
        #expect(discard.messages.count == 1)
        #expect(consequenceQuestion.choices.map(\.localizationKey) == [
            "nightOfTheZealot.theGathering.label.whatsGoingOn.horror",
            "nightOfTheZealot.theGathering.label.whatsGoingOn.discard",
        ])
    }

    private func assertAgendaHorrorAssignmentPrompt() throws {
        let assignmentPayload = try RoundTransitionFixtures.payload(.agendaHorrorAssignment)
        let assignmentQuestion = try #require(assignmentPayload.supportedQuestion)
        #expect(assignmentQuestion.kind == .questionWithSource)
        #expect(assignmentQuestion.choices.map(\.index) == [0])
        guard case let .assignAgendaHorror(assignment) =
            assignmentQuestion.choices[0].content
        else {
            Issue.record("Expected the governed agenda horror assignment")
            return
        }
        #expect(assignment.agendaID == RoundTransitionFixtures.agendaID)
        #expect(assignment.investigatorID == RoundTransitionFixtures.investigatorID)
        #expect(assignment.messages.count == 2)
    }

    private func assertFixtureRoundTrips() throws {
        for fixture in RoundTransitionFixtures.Fixture.allCases {
            let payload = try RoundTransitionFixtures.payload(fixture)
            let reencoded = try ContractJSON.decode(
                JSONValue.self, from: ContractJSON.encode(payload)
            )
            let expected = try RoundTransitionFixtures.value(fixture)
            #expect(reencoded == expected)
        }
    }

    @Test("Current projection identities and deployment-owned labels gate actionability")
    func identitiesAndLabelsGateActionability() throws {
        let projection = RoundTransitionFixtures.projection()

        let forced = try RoundTransitionFixtures.prompt(.forcedAbility)
        #expect(forced.isChoiceActionable(forced.choices[0], in: projection))
        let noTreachery = RoundTransitionFixtures.projection(includeTreachery: false)
        #expect(!forced.isChoiceActionable(forced.choices[0], in: noTreachery))

        let advance = try RoundTransitionFixtures.prompt(.agendaAdvance)
        #expect(advance.isChoiceActionable(advance.choices[0], in: projection))

        let unavailable = try RoundTransitionFixtures.prompt(.agendaConsequence)
        #expect(unavailable.choices.allSatisfy {
            !unavailable.isChoiceActionable($0, in: projection)
        })
        let consequences = try RoundTransitionFixtures.prompt(
            .agendaConsequence,
            labelResolutions: RoundTransitionFixtures.resolvedConsequenceLabels
        )
        #expect(consequences.choices.allSatisfy {
            consequences.isChoiceActionable($0, in: projection)
        })
        #expect(consequences.choices.map {
            BoardDisplayFormatting.choiceDisplayTitle(
                for: $0,
                in: projection,
                labelResolution: consequences.choiceLabelResolutions[$0.index]
            )
        } == [
            "The lead investigator takes 2 horror",
            "Each investigator discards 1 card at random from their hand",
        ])

        let assignment = try RoundTransitionFixtures.prompt(.agendaHorrorAssignment)
        #expect(assignment.isChoiceActionable(assignment.choices[0], in: projection))
        #expect(BoardDisplayFormatting.choiceDisplayTitle(
            for: assignment.choices[0], in: projection
        ) == "Assign 2 horror to Roland Banks")

        let noAgenda = RoundTransitionFixtures.projection(includeAgenda: false)
        #expect(!advance.isChoiceActionable(advance.choices[0], in: noAgenda))
        #expect(consequences.choices.allSatisfy {
            !consequences.isChoiceActionable($0, in: noAgenda)
        })
        #expect(!assignment.isChoiceActionable(assignment.choices[0], in: noAgenda))

        let noInvestigator = RoundTransitionFixtures.projection(includeInvestigator: false)
        #expect(!forced.isChoiceActionable(forced.choices[0], in: noInvestigator))
        #expect(!consequences.isChoiceActionable(consequences.choices[0], in: noInvestigator))
        #expect(consequences.isChoiceActionable(consequences.choices[1], in: noInvestigator))
        #expect(!assignment.isChoiceActionable(assignment.choices[0], in: noInvestigator))
    }

    @Test("Controller focus preserves every authoritative source index")
    func controllerRouting() throws {
        let projection = RoundTransitionFixtures.projection()
        for fixture in [
            RoundTransitionFixtures.Fixture.forcedAbility,
            .agendaAdvance,
            .agendaHorrorAssignment,
        ] {
            var submitted: [Int] = []
            let prompt = try RoundTransitionFixtures.prompt(fixture)
            let controller = BoardCommandController(
                projection: projection,
                prompt: prompt,
                onChoice: { submitted.append($0) }
            )
            #expect(controller.handle(.command(.jumpToActivePrompt)))
            #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(0))
            #expect(controller.handle(.command(.primaryAction)))
            #expect(submitted == [0])
        }

        var consequencesSubmitted: [Int] = []
        let consequencePrompt = try RoundTransitionFixtures.prompt(
            .agendaConsequence,
            labelResolutions: RoundTransitionFixtures.resolvedConsequenceLabels
        )
        let consequenceController = BoardCommandController(
            projection: projection,
            prompt: consequencePrompt,
            onChoice: { consequencesSubmitted.append($0) }
        )
        #expect(consequenceController.handle(.command(.jumpToActivePrompt)))
        #expect(consequenceController.coordinator.currentFocus == BoardFocusID.promptChoice(0))
        #expect(consequenceController.handle(.command(.focusMove(.down))))
        #expect(consequenceController.coordinator.currentFocus == BoardFocusID.promptChoice(1))
        #expect(consequenceController.handle(.command(.primaryAction)))
        #expect(consequencesSubmitted == [1])
    }

    @Test("Backend-published round-transition mutations never gain action authority")
    func governedMutationsFailClosed() throws {
        let manifest = try ContractJSON.decode(
            JSONValue.self,
            from: DamageAssignmentFixtures.data("manifest")
        )
        guard case let .object(root) = manifest,
              case let .array(negatives)? = root["negativeFixtures"]
        else { throw TestFailure() }

        let fixtureByPath = Dictionary(uniqueKeysWithValues:
            RoundTransitionFixtures.Fixture.allCases.map {
                ("contracts/fixtures/\($0.rawValue).json", $0)
            })
        var checked = 0
        for case let .object(entry) in negatives {
            guard case let .string(path)? = entry["basePositiveFixture"],
                  let fixture = fixtureByPath[path],
                  case let .string(base)? = entry["basePointer"],
                  case let .object(mutation)? = entry["mutation"],
                  case let .string(pointer)? = mutation["pointer"],
                  case let .string(operation)? = mutation["op"]
            else { continue }
            let mutated = try EnemyAttackFixtures.applying(
                operation: operation,
                path: (base + pointer).split(separator: "/"),
                replacement: mutation["value"],
                to: RoundTransitionFixtures.value(fixture)
            )
            let payload = try ContractJSON.decode(
                BasicChoiceQuestionPayload.self,
                from: ContractJSON.encode(mutated)
            )
            if let question = payload.supportedQuestion {
                #expect(question.choices.allSatisfy { !$0.isSupported })
            }
            checked += 1
        }
        #expect(checked == 55)
    }

    @Test("Agenda advancement rejects a different internally consistent agenda ID")
    func agendaAdvanceRejectsOtherAgenda() throws {
        var mutated = try RoundTransitionFixtures.value(.agendaAdvance)
        mutated = try EnemyAttackFixtures.applying(
            operation: "replace",
            path: ["choices", "0", "target", "contents"],
            replacement: .string("c01106"),
            to: mutated
        )
        mutated = try EnemyAttackFixtures.applying(
            operation: "replace",
            path: ["choices", "0", "messages", "0", "contents", "0"],
            replacement: .string("c01106"),
            to: mutated
        )

        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: ContractJSON.encode(mutated)
        )
        let question = try #require(payload.supportedQuestion)
        #expect(question.choices.count == 1)
        #expect(!question.choices[0].isSupported)
    }
}

@MainActor
@Suite("Round-transition agenda source identity")
struct RoundTransitionAgendaSourceTests {
    @Test("Agenda consequences and assignment reject another internally consistent agenda source")
    func agendaEffectsRejectOtherAgenda() throws {
        var consequence = try RoundTransitionFixtures.value(.agendaConsequence)
        for path in [
            "choices/0/messages/0/contents/contents/1/contents",
            "choices/1/messages/0/contents/0/contents",
        ] {
            consequence = try EnemyAttackFixtures.applying(
                operation: "replace",
                path: path.split(separator: "/"),
                replacement: .string("c01106"),
                to: consequence
            )
        }

        let consequencePayload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: ContractJSON.encode(consequence)
        )
        let consequenceQuestion = try #require(consequencePayload.supportedQuestion)
        #expect(consequenceQuestion.choices.allSatisfy { !$0.isSupported })

        var assignment = try RoundTransitionFixtures.value(.agendaHorrorAssignment)
        for path in [
            "source/contents",
            "question/question/choices/0/messages/0/contents/contents/1/contents",
            "question/question/choices/0/messages/1/contents/contents/1/contents",
        ] {
            assignment = try EnemyAttackFixtures.applying(
                operation: "replace",
                path: path.split(separator: "/"),
                replacement: .string("c01106"),
                to: assignment
            )
        }

        let assignmentPayload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: ContractJSON.encode(assignment)
        )
        #expect(assignmentPayload.isUpdateRequired)
    }
}
