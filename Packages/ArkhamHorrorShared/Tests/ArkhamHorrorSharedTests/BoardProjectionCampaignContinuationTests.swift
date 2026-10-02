@testable import ArkhamHorrorShared
import Testing

@Suite("BoardProjection — campaign continuation")
struct BoardProjectionCampaignContinuationTests {
    private func continueCampaignStep(
        nextStep: JSONValue,
        canUpgradeDecks: Bool = false
    ) -> JSONValue {
        .object([
            "tag": .string("ContinueCampaignStep"),
            "contents": .object([
                "canChooseSideStory": .bool(false),
                "canUpgradeDecks": .bool(canUpgradeDecks),
                "chooseSideStory": .bool(false),
                "nextStep": nextStep,
            ]),
        ])
    }

    private func campaign(
        step: JSONValue,
        completedSteps: [JSONValue] = []
    ) -> JSONValue {
        .object([
            "completedSteps": .array(completedSteps),
            "step": step,
        ])
    }

    private func continuationProjection(
        campaignStep: JSONValue,
        scenarioStep: JSONValue = .null,
        completedSteps: [JSONValue] = []
    ) -> BoardProjection {
        BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            mode: .campaignAndScenario(
                campaign: campaign(step: campaignStep, completedSteps: completedSteps),
                scenario: BoardTestFixtures.scenario(campaignStep: scenarioStep)
            )
        ))
    }

    @Test("Campaign continuation keeps the campaign next step for non-continuation scenario steps")
    func campaignContinuationPrecedenceUsesCampaignStep() {
        let campaignNext: JSONValue = .object(["tag": .string("ScenarioStep")])
        let projection = continuationProjection(
            campaignStep: continueCampaignStep(nextStep: campaignNext),
            scenarioStep: .object(["tag": .string("CampaignSpecificStep")])
        )

        #expect(projection.campaignContinuation?.source == .campaign)
        #expect(projection.campaignContinuation?.nextStep == campaignNext)
    }

    @Test("Scenario ContinueCampaignStep takes precedence over the campaign continuation")
    func scenarioContinueCampaignStepTakesPrecedence() {
        let campaignNext: JSONValue = .object(["tag": .string("ScenarioStep")])
        let scenarioNext: JSONValue = .object(["tag": .string("ScenarioStepWithOptions")])
        let projection = continuationProjection(
            campaignStep: continueCampaignStep(nextStep: campaignNext),
            scenarioStep: continueCampaignStep(nextStep: scenarioNext)
        )

        #expect(projection.campaignContinuation?.source == .scenario)
        #expect(projection.campaignContinuation?.nextStep == scenarioNext)
    }

    @Test("ScenarioStep overrides the campaign ContinueCampaign next step")
    func scenarioStepOverridesCampaignNextStep() {
        let campaignNext: JSONValue = .object(["tag": .string("InterludeStep")])
        let scenarioStep: JSONValue = .object(["tag": .string("ScenarioStep")])
        let projection = continuationProjection(
            campaignStep: continueCampaignStep(nextStep: campaignNext),
            scenarioStep: scenarioStep
        )

        #expect(projection.campaignContinuation?.source == .campaign)
        #expect(projection.campaignContinuation?.nextStep == scenarioStep)
    }

    @Test("Nested StandaloneScenarioStep continuation unwraps to its inner next step")
    func nestedStandaloneScenarioContinuationUnwraps() {
        let innerNext: JSONValue = .object(["tag": .string("ScenarioStep")])
        let standalone: JSONValue = .object([
            "tag": .string("StandaloneScenarioStep"),
            "contents": .array([
                .string("c81001"),
                continueCampaignStep(nextStep: innerNext),
            ]),
        ])
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            mode: .campaignOnly(campaign(step: standalone))
        ))

        #expect(projection.campaignContinuation?.source == .campaign)
        #expect(projection.campaignContinuation?.nextStep == innerNext)
    }

    @Test("Non-scenario scenario steps fall back to the campaign continuation")
    func nonScenarioOverrideFallsBackToCampaignContinuation() {
        let campaignNext: JSONValue = .object(["tag": .string("ScenarioStepWithOptions")])
        let projection = continuationProjection(
            campaignStep: continueCampaignStep(nextStep: campaignNext),
            scenarioStep: .object(["tag": .string("InterludeStep")])
        )

        #expect(projection.campaignContinuation?.nextStep == campaignNext)
    }

    @Test("Upgrade deck remains hidden after the prologue with no completed scenario")
    func upgradeDeckHiddenAfterPrologue() {
        let nextScenario: JSONValue = .object(["tag": .string("ScenarioStep")])
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            mode: .campaignOnly(campaign(
                step: continueCampaignStep(nextStep: nextScenario, canUpgradeDecks: true),
                completedSteps: []
            ))
        ))

        #expect(projection.campaignContinuation?.canUpgradeDecks == true)
        #expect(projection.campaignContinuation?.canUpgrade == false)
    }

    @Test("Upgrade deck becomes visible only after a completed scenario step")
    func upgradeDeckVisibleAfterCompletedScenario() {
        let nextScenario: JSONValue = .object(["tag": .string("ScenarioStep")])
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            mode: .campaignOnly(campaign(
                step: continueCampaignStep(nextStep: nextScenario, canUpgradeDecks: true),
                completedSteps: [.object(["tag": .string("StandaloneScenarioStep")])]
            ))
        ))

        #expect(projection.campaignContinuation?.canUpgrade == true)
    }
}
