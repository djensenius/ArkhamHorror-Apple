@testable import ArkhamHorrorShared
import Testing

@Suite("BoardProjection — campaign summary")
struct BoardProjectionCampaignSummaryTests {
    private let investigatorID = BoardTestFixtures.investigatorID("c01001")

    private var campaignLogKey: JSONValue {
        .object([
            "tag": .string("TheGatheringKey"),
            "contents": .string("TheHouseBurnedDown"),
        ])
    }

    private var crossedOutKey: JSONValue {
        .object([
            "tag": .string("TheGatheringKey"),
            "contents": .string("TheInvestigatorsWereForcedToWait"),
        ])
    }

    private func continueCampaignStep(nextStep: JSONValue) -> JSONValue {
        .object([
            "tag": .string("ContinueCampaignStep"),
            "contents": .object([
                "canChooseSideStory": .bool(false),
                "canUpgradeDecks": .bool(false),
                "chooseSideStory": .bool(false),
                "nextStep": nextStep,
            ]),
        ])
    }

    private func campaign() -> JSONValue {
        .object([
            "completedSteps": .array([.object([
                "tag": .string("ScenarioStep"),
                "contents": .string("01104"),
            ])]),
            "step": continueCampaignStep(nextStep: .object(["tag": .string("ScenarioStep")])),
            "log": campaignLog(),
            "resolutions": .object([
                "01104": .object([
                    "tag": .string("Resolution"),
                    "contents": .number(.integer(2)),
                ]),
            ]),
        ])
    }

    private func campaignLog() -> JSONValue {
        .object([
            "recorded": .array([campaignLogKey]),
            "crossedOut": .array([crossedOutKey]),
            "recordedCounts": .array([.array([campaignLogKey, .number(.integer(2))])]),
            "recordedSets": .array([.array([
                .object(["tag": .string("KilledInvestigators")]),
                .array([recordedInvestigator("c01001"), crossedOutInvestigator("c01002")]),
            ])]),
        ])
    }

    private func recordedInvestigator(_ code: String) -> JSONValue {
        recordedValue(tag: "Recorded", contents: code)
    }

    private func crossedOutInvestigator(_ code: String) -> JSONValue {
        recordedValue(tag: "CrossedOut", contents: code)
    }

    private func recordedValue(tag: String, contents: String) -> JSONValue {
        .object([
            "recordType": .string("RecordableCardCode"),
            "recordVal": .object([
                "tag": .string(tag),
                "contents": .string(contents),
            ]),
        ])
    }

    private func projection() -> BoardProjection {
        BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            mode: .campaignOnly(campaign()),
            investigators: [
                investigatorID: BoardTestFixtures.investigator(
                    id: investigatorID,
                    name: CardName(title: "Roland Banks", subtitle: nil),
                    physicalTrauma: 1,
                    mentalTrauma: 2,
                    killed: true,
                    spentXp: 3,
                    experiencePoints: 8
                ),
            ],
            playerOrder: [investigatorID]
        ))
    }

    @Test("Campaign handoff summary formats server log, resolution, XP, and trauma")
    func campaignHandoffSummaryUsesServerValues() throws {
        let summary = try #require(projection().campaignSummary)

        #expect(summary.latestResolution?.title == "Resolution 2")
        #expect(summary.latestResolution?.detail == "01104")
        #expect(summary.log.entries.map(\.title) == [
            "The house burned down",
            "The investigators were forced to wait",
        ])
        #expect(summary.log.entries.map(\.isCrossedOut) == [false, true])
        #expect(summary.log.counts.first?.value == 2)
        #expect(summary.log.recordedSets.first?.title == "Killed investigators")
        #expect(summary.log.recordedSets.first?.values.map(\.title) == ["C01001", "C01002"])
        #expect(summary.log.recordedSets.first?.values.map(\.isCrossedOut) == [false, true])
        #expect(summary.investigators.first?.displayName == "Roland Banks")
        #expect(summary.investigators.first?.availableExperience == 5)
        #expect(summary.investigators.first?.physicalTrauma == 1)
        #expect(summary.investigators.first?.mentalTrauma == 2)
        #expect(summary.investigators.first?.killed == true)
    }
}
