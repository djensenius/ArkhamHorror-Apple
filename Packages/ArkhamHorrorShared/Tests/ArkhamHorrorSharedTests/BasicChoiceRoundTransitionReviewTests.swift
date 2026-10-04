@testable import ArkhamHorrorShared
import Testing

extension BasicChoiceRoundTransitionTests {
    @Test("Q24 Dissonant Voices binds server presentation and remains actionable")
    func q24DissonantVoicesBindsAndActivates() throws {
        let payload = try RoundTransitionFixtures.payload(.forcedAbility)
        let presentation = QuestionPresentation(
            protocolVersion: QuestionPresentation.supportedProtocolVersion,
            questionVersion: 24,
            questionKind: .windowChooseOne,
            choiceCount: 1,
            choices: [dissonantVoicesPresentationChoice()]
        )
        let binding = try presentation.bind(
            to: payload.rawValue,
            expectedQuestionVersion: 24
        )
        let descriptor = try #require(binding.descriptor(forSourceIndex: 0))
        let catalog = try dissonantVoicesCatalog()
        let prompt = BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: 24,
                rawQuestion: payload.rawValue,
                questionPresentation: presentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            semanticPresentation: binding,
            semanticLocaleIdentifier: "en",
            cardCatalog: catalog,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
        let choice = try #require(prompt.choices.first)
        let projection = RoundTransitionFixtures.projection()

        #expect(descriptor.kind == .resolveForcedAbility)
        #expect(descriptor.entity == .init(
            kind: .treachery,
            id: RoundTransitionFixtures.treacheryID.codingKey.stringValue
        ))
        #expect(descriptor.ability?.cardCode == "c01165")
        #expect(binding.canActivateSemanticChoice(descriptor, labelResolution: nil))
        #expect(prompt.isChoiceActionable(choice, in: projection))
        #expect(
            prompt.displayTitle(for: choice, in: projection)
                == "Resolve forced ability at Dissonant Voices (Free)"
        )
    }

    private func dissonantVoicesPresentationChoice() -> QuestionPresentation.Choice {
        // Mirrors the server's v2 generic treachery-forced presentation shape, specialized
        // to Q24's Dissonant Voices cleanup bytes so this test fails if binding rejects them.
        QuestionPresentation.Choice(
            sourceIndex: 0,
            kind: .resolveForcedAbility,
            actorID: RoundTransitionFixtures.investigatorID.codingKey.stringValue,
            entity: .init(
                kind: .treachery,
                id: RoundTransitionFixtures.treacheryID.codingKey.stringValue
            ),
            label: nil,
            ability: .init(
                cardCode: "c01165",
                index: 1,
                type: .forced,
                actions: [],
                canBeCancelled: true
            ),
            cost: .free
        )
    }

    private func dissonantVoicesCatalog() throws -> CardCatalogSnapshot {
        try CardCatalogSnapshot(namesByCode: [
            CardCode("c01165"): CardName(title: "Dissonant Voices", subtitle: nil),
        ])
    }
}
