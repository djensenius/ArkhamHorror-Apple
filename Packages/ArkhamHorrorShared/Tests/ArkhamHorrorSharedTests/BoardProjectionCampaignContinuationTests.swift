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
        id: String? = nil,
        step: JSONValue,
        completedSteps: [JSONValue] = []
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "completedSteps": .array(completedSteps),
            "step": step,
        ]
        if let id {
            object["id"] = .string(id)
        }
        return .object(object)
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

    private func campaignI18nProjection(campaignID: String) -> BoardProjection {
        BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            mode: .campaignOnly(campaign(id: campaignID, step: .null))
        ))
    }

    @Test("Zero-padded built-in campaign IDs map to their campaign i18n scope")
    func zeroPaddedBuiltInCampaignIDMapsToI18nScope() {
        let projection = campaignI18nProjection(campaignID: "05")

        #expect(projection.campaignI18nScope == "theCircleUndone")
    }

    @Test("Homebrew campaign IDs map from kebab ID to camel-case i18n scope")
    func homebrewCampaignIDMapsToCamelCaseI18nScope() {
        let projection = campaignI18nProjection(campaignID: ":kebab-id")

        #expect(projection.campaignI18nScope == "kebabId")
    }

    @Test("Return To campaign IDs do not map to a campaign i18n scope")
    func returnToCampaignIDDoesNotMapToI18nScope() {
        let projection = campaignI18nProjection(campaignID: "54")

        #expect(projection.campaignI18nScope == nil)
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

        // Campaign.vue lines 123-130 return null for continueCampaign when the
        // scenario owns a ContinueCampaignStep; lines 173-182 compute continueScenario,
        // and lines 234-242 render it with the scenario's nextStep and no campaign prop.
        #expect(projection.campaignContinuation?.source == .scenario)
        #expect(projection.campaignContinuation?.nextStep == scenarioNext)
        #expect(projection.campaignContinuation?.canUpgrade == false)
    }

    @Test("Scenario fallback continuation keeps web upgrade hidden")
    func scenarioFallbackContinuationKeepsWebUpgradeHidden() {
        let scenarioNext: JSONValue = .object(["tag": .string("ScenarioStep")])
        let standalone: JSONValue = .object([
            "tag": .string("StandaloneScenarioStep"),
            "contents": .array([
                .string("c81001"),
                continueCampaignStep(nextStep: scenarioNext, canUpgradeDecks: true),
            ]),
        ])
        let projection = continuationProjection(
            campaignStep: .object(["tag": .string("CampaignSpecificStep")]),
            scenarioStep: standalone,
            completedSteps: [.object(["tag": .string("ScenarioStep")])]
        )

        // The campaign branch passes :campaign at Campaign.vue:214, but the scenario
        // branch at Campaign.vue:234-242 does not. ContinueCampaign.vue's canUpgrade
        // begins with `if (!props.campaign) return false`, so scenario-sourced
        // continuations must not inherit campaign upgrade eligibility.
        #expect(projection.campaignContinuation?.source == .scenario)
        #expect(projection.campaignContinuation?.nextStep == scenarioNext)
        #expect(projection.campaignContinuation?.canUpgradeDecks == true)
        #expect(projection.campaignContinuation?.canUpgrade == false)
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

    @Test("Campaign-and-scenario mode falls back to scenario step without campaign continuation")
    func campaignAndScenarioFallsBackToScenarioStepWithoutCampaignContinuation() {
        let scenarioStep: JSONValue = .object(["tag": .string("InterludeStep")])
        let projection = continuationProjection(
            campaignStep: .object(["tag": .string("CampaignSpecificStep")]),
            scenarioStep: scenarioStep
        )

        #expect(projection.campaignContinuation?.source == .scenario)
        #expect(projection.campaignContinuation?.nextStep == scenarioStep)
        #expect(projection.campaignContinuation?.canUpgradeDecks == false)
    }

    @Test("Upgrade deck remains hidden without campaign context")
    func upgradeDeckHiddenWithoutCampaignContext() {
        let nextScenario: JSONValue = .object(["tag": .string("ScenarioStep")])
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            mode: .scenarioOnly(BoardTestFixtures.scenario(
                campaignStep: continueCampaignStep(nextStep: nextScenario, canUpgradeDecks: true)
            ))
        ))

        #expect(projection.campaignContinuation?.canUpgradeDecks == true)
        #expect(projection.campaignContinuation?.canUpgrade == false)
    }

    @Test("Upgrade deck remains hidden when the server flag is false")
    func upgradeDeckHiddenWhenServerFlagIsFalse() {
        let nextScenario: JSONValue = .object(["tag": .string("ScenarioStep")])
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            mode: .campaignOnly(campaign(
                step: continueCampaignStep(nextStep: nextScenario, canUpgradeDecks: false),
                completedSteps: [.object(["tag": .string("ScenarioStep")])]
            ))
        ))

        #expect(projection.campaignContinuation?.canUpgradeDecks == false)
        #expect(projection.campaignContinuation?.canUpgrade == false)
    }

    @Test("Upgrade deck is visible for CampaignSpecificStep when the server allows it")
    func upgradeDeckVisibleForCampaignSpecificStep() {
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            mode: .campaignOnly(campaign(
                step: continueCampaignStep(
                    nextStep: .object(["tag": .string("CampaignSpecificStep")]),
                    canUpgradeDecks: true
                ),
                completedSteps: []
            ))
        ))

        #expect(projection.campaignContinuation?.canUpgrade == true)
    }

    @Test("Upgrade deck remains hidden for non-scenario steps")
    func upgradeDeckHiddenForNonScenarioStep() {
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            mode: .campaignOnly(campaign(
                step: continueCampaignStep(
                    nextStep: .object(["tag": .string("InterludeStep")]),
                    canUpgradeDecks: true
                ),
                completedSteps: [.object(["tag": .string("ScenarioStep")])]
            ))
        ))

        #expect(projection.campaignContinuation?.canUpgrade == false)
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

    @Test(
        "Upgrade deck becomes visible after each web scenario step variant",
        arguments: ["ScenarioStep", "ScenarioStepWithOptions", "StandaloneScenarioStep"]
    )
    func upgradeDeckVisibleAfterCompletedScenario(completedStepTag: String) {
        let nextScenario: JSONValue = .object(["tag": .string("ScenarioStep")])
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            mode: .campaignOnly(campaign(
                step: continueCampaignStep(nextStep: nextScenario, canUpgradeDecks: true),
                completedSteps: [.object(["tag": .string(completedStepTag)])]
            ))
        ))

        #expect(projection.campaignContinuation?.canUpgrade == true)
    }
}
