import Foundation

/// Builds a deterministic ``BoardProjection`` from a decoded ``PublicGameSnapshot``.
///
/// This is the sole place that reads the raw snapshot's `Dictionary`-backed maps
/// (`UUIDKeyedMap`/plain `[Key: Value]`) and turns them into stably-ordered arrays: every
/// sort key here is a plain value (`UUID` text, `Int`, or `CardCode` text) compared with
/// `String`/`Int`'s own `<` operator, never `Dictionary` iteration order and never a
/// locale-sensitive comparison. Two snapshots with equal field values always build to an
/// equal ``BoardProjection`` regardless of map insertion order.
enum BoardProjectionBuilder { // swiftlint:disable:this type_body_length
    static func makeProjection(from snapshot: PublicGameSnapshot) -> BoardProjection {
        let scenarioContext = makeScenario(from: snapshot.mode)
        let (locations, enemyLocations) = makeLocations(from: snapshot.locations)
        let investigatorLocations = makeInvestigatorLocationLookup(
            locations: locations, enemyLocations: enemyLocations
        )
        let investigators = makeInvestigators(
            from: snapshot, currentLocations: investigatorLocations
        )
        let enemyPlacement = makeEnemyPlacement(
            from: snapshot, locations: locations, enemyLocations: enemyLocations
        )
        return BoardProjection(
            gameName: safeGameName(snapshot),
            hasCampaignContext: scenarioContext.hasCampaignContext,
            scenario: scenarioContext.scenario,
            campaignContinuation: scenarioContext.campaignContinuation,
            campaignSummary: BoardCampaignSummaryBuilder.makeSummary(
                campaign: scenarioContext.campaign,
                scenario: scenarioContext.scenarioSource,
                investigators: makeCampaignInvestigatorProgress(from: snapshot)
            ),
            acts: makeActs(from: snapshot.acts),
            agendas: makeAgendas(from: snapshot.agendas),
            locations: locations,
            enemyLocations: enemyLocations,
            investigators: investigators,
            playerOrderCount: snapshot.playerOrder.count,
            enemyIDs: snapshot.enemies.keys.sorted {
                $0.codingKey.stringValue < $1.codingKey.stringValue
            },
            treacheryIDs: snapshot.treacheries.keys.sorted {
                $0.codingKey.stringValue < $1.codingKey.stringValue
            },
            treacheriesByID: makeTreacheryNodes(from: snapshot.treacheries),
            otherInvestigatorCount: snapshot.otherInvestigators.count,
            killedInvestigatorCount: snapshot.killedInvestigators.count,
            handCardsByPlayer: makeHandCards(from: snapshot),
            orderedHandCardsByPlayer: makeOrderedHandCards(from: snapshot),
            inPlayCardsByPlayer: makeInPlayCards(from: snapshot),
            threatTreacheriesByPlayer: makeThreatTreacheries(from: snapshot),
            enemiesByLocationID: enemyPlacement.byLocationID,
            engagedEnemiesByInvestigatorID: enemyPlacement.engagedByInvestigatorID,
            chaosBag: makeChaosBag(from: snapshot.mode),
            counters: makeCounters(from: snapshot),
            skillTest: BoardSkillTestProjectionBuilder.makeProjection(
                skillTest: snapshot.skillTest, results: snapshot.skillTestResults
            ),
            questions: snapshot.question
        )
    }

    private static func safeGameName(_ snapshot: PublicGameSnapshot) -> String {
        BoardDisplayFormatting.safeLabel(snapshot.name, fallback: snapshot.id.description)
    }

    // MARK: - Scenario / campaign

    private struct ScenarioBuildContext {
        let hasCampaignContext: Bool
        let scenario: BoardScenarioSummary?
        let scenarioSource: Scenario?
        let campaign: JSONValue?
        let campaignContinuation: CampaignContinuationContext?
    }

    private struct ContinuationContents {
        let nextStep: JSONValue
        let canUpgradeDecks: Bool
        let chooseSideStory: Bool
        let canChooseSideStory: Bool
    }

    private static func makeScenario(from mode: GameMode) -> ScenarioBuildContext {
        switch mode {
        case let .campaignOnly(campaign):
            return ScenarioBuildContext(
                hasCampaignContext: true,
                scenario: nil,
                scenarioSource: nil,
                campaign: campaign,
                campaignContinuation: makeCampaignContinuation(fromCampaign: campaign)
            )
        case let .scenarioOnly(scenario):
            return ScenarioBuildContext(
                hasCampaignContext: false,
                scenario: makeScenarioSummary(scenario),
                scenarioSource: scenario,
                campaign: nil,
                campaignContinuation: makeCampaignContinuation(
                    fromScenarioStep: scenario.campaignStep
                )
            )
        case let .campaignAndScenario(campaign, scenario):
            let scenarioStep = scenario.campaignStep
            let campaignContinuation = if scenarioStep.tag == "ContinueCampaignStep" {
                makeCampaignContinuation(fromScenarioStep: scenarioStep)
            } else {
                makeCampaignContinuation(
                    fromCampaign: campaign,
                    scenarioContinuationStep: scenarioStep.scenarioContinuationStep
                ) ?? makeCampaignContinuation(fromScenarioStep: scenarioStep)
            }
            return ScenarioBuildContext(
                hasCampaignContext: true,
                scenario: makeScenarioSummary(scenario),
                scenarioSource: scenario,
                campaign: campaign,
                campaignContinuation: campaignContinuation
            )
        }
    }

    private static func makeCampaignContinuation(
        fromCampaign campaign: JSONValue,
        scenarioContinuationStep: JSONValue? = nil
    ) -> CampaignContinuationContext? {
        guard case let .object(object) = campaign,
              let step = object["step"]
        else { return nil }
        return makeCampaignContinuation(
            fromCampaignStep: step,
            source: .campaign,
            nextStepOverride: scenarioContinuationStep,
            campaign: campaign
        )
    }

    private static func makeCampaignContinuation(
        fromScenarioStep step: JSONValue
    ) -> CampaignContinuationContext? {
        makeCampaignContinuation(fromCampaignStep: step, source: .scenario)
    }

    private static func makeCampaignContinuation(
        fromCampaignStep step: JSONValue,
        source: CampaignContinuationContext.Source,
        nextStepOverride: JSONValue? = nil,
        campaign: JSONValue? = nil
    ) -> CampaignContinuationContext? {
        if let continuation = continuationContents(in: step) {
            let nextStep = nextStepOverride ?? continuation.nextStep
            return CampaignContinuationContext(
                source: source,
                nextStep: nextStep,
                canUpgradeDecks: continuation.canUpgradeDecks,
                chooseSideStory: continuation.chooseSideStory,
                canChooseSideStory: continuation.canChooseSideStory,
                canUpgrade: campaign.map {
                    canUpgrade(
                        campaign: $0,
                        nextStep: nextStep,
                        canUpgradeDecks: continuation.canUpgradeDecks
                    )
                } ?? false
            )
        }
        if source == .scenario, step != .null {
            return CampaignContinuationContext(
                source: source,
                nextStep: step,
                canUpgradeDecks: false,
                chooseSideStory: false,
                canChooseSideStory: false,
                canUpgrade: false
            )
        }
        return nil
    }

    private static func continuationContents(in step: JSONValue) -> ContinuationContents? {
        guard case let .object(object) = step,
              case .string("ContinueCampaignStep")? = object["tag"],
              case let .object(contents)? = object["contents"],
              let nextStep = contents["nextStep"]
        else {
            return nestedContinuationContents(in: step)
        }
        return ContinuationContents(
            nextStep: nextStep,
            canUpgradeDecks: contents["canUpgradeDecks"]?.boolValue ?? false,
            chooseSideStory: contents["chooseSideStory"]?.boolValue ?? false,
            canChooseSideStory: contents["canChooseSideStory"]?.boolValue ?? false
        )
    }

    private static func nestedContinuationContents(in step: JSONValue) -> ContinuationContents? {
        guard case let .object(object) = step,
              case .string("StandaloneScenarioStep")? = object["tag"],
              case let .array(contents)? = object["contents"],
              contents.count > 1
        else { return nil }
        return continuationContents(in: contents[1])
    }

    private static func canUpgrade(
        campaign: JSONValue,
        nextStep: JSONValue,
        canUpgradeDecks: Bool
    ) -> Bool {
        guard canUpgradeDecks else { return false }
        if nextStep.tag == "CampaignSpecificStep" {
            return true
        }
        guard nextStep.isScenarioContinuation,
              case let .object(object) = campaign,
              case let .array(completedSteps)? = object["completedSteps"]
        else { return false }
        return completedSteps.contains { $0.isScenarioContinuation }
    }

    private static func makeScenarioSummary(_ scenario: Scenario) -> BoardScenarioSummary {
        BoardScenarioSummary(
            displayName: BoardDisplayFormatting.safeTitle(
                scenario.name, fallback: scenario.id.description
            ),
            subtitle: BoardDisplayFormatting.safeSubtitle(scenario.name),
            difficulty: scenario.difficulty,
            turn: scenario.turn,
            reference: scenario.reference,
            usesGrid: scenario.usesGrid,
            isPrelude: scenario.isPrelude,
            isSideStory: scenario.isSideStory,
            inResolution: scenario.inResolution,
            started: scenario.started
        )
    }

    private static func makeChaosBag(from mode: GameMode) -> BoardChaosBagState {
        let scenario: Scenario? = switch mode {
        case .campaignOnly: nil
        case let .scenarioOnly(scenario): scenario
        case let .campaignAndScenario(_, scenario): scenario
        }
        guard let scenario else {
            return .noActiveScenario
        }
        let bag = scenario.chaosBag
        return .scenario(BoardChaosBagSummary(
            poolCounts: BoardDisplayFormatting.groupChaosFaceCounts(bag.chaosTokens),
            revealedCounts: BoardDisplayFormatting.groupChaosFaceCounts(bag.revealedChaosTokens),
            setAsideCounts: BoardDisplayFormatting.groupChaosFaceCounts(bag.setAsideChaosTokens),
            forceDrawFace: bag.forceDraw,
            hasPendingChoice: bag.choice != nil
        ))
    }

    // MARK: - Counters

    private static func makeCounters(from snapshot: PublicGameSnapshot) -> BoardCounters {
        BoardCounters(
            totalDoom: snapshot.totalDoom,
            totalClues: snapshot.totalClues,
            encounterDeckSize: snapshot.encounterDeckSize,
            scenarioSteps: snapshot.scenarioSteps,
            playerCount: snapshot.playerCount,
            phase: snapshot.phase,
            phaseStepSummary: BoardDisplayFormatting.phaseStepSummary(snapshot.phaseStep),
            gameStateSummary: BoardDisplayFormatting.gameStateSummary(snapshot.gameState),
            inSetup: snapshot.inSetup,
            inAction: snapshot.inAction,
            pendingPromptCount: snapshot.question.count,
            entityCounters: BoardEntityCounters(
                enemies: snapshot.enemies.count,
                assets: snapshot.assets.count,
                treacheries: snapshot.treacheries.count,
                events: snapshot.events.count,
                skills: snapshot.skills.count,
                concealed: snapshot.concealed.count,
                cards: snapshot.cards.count
            )
        )
    }
}

private extension JSONValue {
    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var tag: String? {
        guard case let .object(object) = self,
              case let .string(tag)? = object["tag"]
        else { return nil }
        return tag
    }

    var scenarioContinuationStep: JSONValue? {
        switch tag {
        case "ScenarioStep", "ScenarioStepWithOptions":
            self
        default:
            nil
        }
    }

    var isScenarioContinuation: Bool {
        switch tag {
        case "ScenarioStep", "ScenarioStepWithOptions", "StandaloneScenarioStep":
            true
        default:
            false
        }
    }
}
