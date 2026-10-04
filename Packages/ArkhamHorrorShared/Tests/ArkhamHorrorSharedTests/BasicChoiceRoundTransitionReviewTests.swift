@testable import ArkhamHorrorShared
import Testing

extension BasicChoiceRoundTransitionTests {
    @Test("Q24 Dissonant Voices binds the treachery and remains actionable")
    func q24DissonantVoicesBindsAndActivates() throws {
        let prompt = try RoundTransitionFixtures.prompt(.forcedAbility)
        let choice = try #require(prompt.choices.first)
        guard case let .resolveForcedAbility(forced) = choice.content else {
            Issue.record("Expected Dissonant Voices to bind as a forced ability")
            return
        }

        #expect(prompt.identity.questionVersion == 24)
        #expect(choice.index == 0)
        #expect(forced.treacheryID == RoundTransitionFixtures.treacheryID)
        #expect(forced.ability.cardCode.rawValue == "c01165")
        #expect(forced.ability.investigatorID == RoundTransitionFixtures.investigatorID)
        #expect(prompt.isChoiceActionable(choice, in: RoundTransitionFixtures.projection()))
    }
}
