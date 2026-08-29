import Foundation

/// `CreateGameRequest`'s `campaignId`/`scenarioId` invariant made a representable type
/// rather than two independently-optional strings validated only at encode time: exactly
/// one of "campaign only", "campaign with a starting scenario", or "scenario only" is ever
/// constructible, and every case's identifier is guaranteed non-empty.
///
/// Both the encoder *and* the decoder route through ``init(campaignId:scenarioId:)``, so an
/// invalid wire combination (neither present, both null, or either present-but-empty) is
/// rejected identically on the way in and the way out — there is no longer a decode path
/// that can construct a `CreateGameRequest` the encoder itself would refuse to write.
///
/// Each case stores a validated ``NonEmptyString`` rather than a raw `String`, so an empty
/// identifier cannot be smuggled in by constructing a case directly (`.campaignOnly(campaignId:
/// "")`) and bypassing ``init(campaignId:scenarioId:)`` entirely — `NonEmptyString`'s own
/// only initializer already throws for an empty string, so there is no way to obtain one
/// that holds `""` in the first place, anywhere in the module.
enum CampaignOrScenario: Sendable, Equatable, Hashable {
    /// Phantom tag distinguishing a validated campaign identifier from other opaque
    /// identifier types (for example ``InvestigatorCode``), even though both wrap `String`.
    enum CampaignIDTag: Sendable {}
    /// A validated, non-empty campaign identifier.
    typealias CampaignID = NonEmptyString<CampaignIDTag>

    /// Phantom tag distinguishing a validated scenario identifier; see ``CampaignIDTag``.
    enum ScenarioIDTag: Sendable {}
    /// A validated, non-empty scenario identifier.
    typealias ScenarioID = NonEmptyString<ScenarioIDTag>

    case campaignOnly(campaignId: CampaignID)
    case campaignWithStartingScenario(campaignId: CampaignID, scenarioId: ScenarioID)
    case scenarioOnly(scenarioId: ScenarioID)

    enum ValidationError: Error, Equatable, Sendable {
        /// `campaignId` was provided as an empty string. Per the contract, a present
        /// identifier must be non-empty — use `nil` to mean "absent" instead.
        case emptyCampaignId
        /// `scenarioId` was provided as an empty string; see ``emptyCampaignId``.
        case emptyScenarioId
        /// Both `campaignId` and `scenarioId` are absent; at least one must be present.
        case missingCampaignOrScenario
    }

    init(campaignId: String?, scenarioId: String?) throws {
        let validatedCampaignId: CampaignID?
        if let campaignId {
            guard let validated = try? CampaignID(campaignId) else {
                throw ValidationError.emptyCampaignId
            }
            validatedCampaignId = validated
        } else {
            validatedCampaignId = nil
        }
        let validatedScenarioId: ScenarioID?
        if let scenarioId {
            guard let validated = try? ScenarioID(scenarioId) else {
                throw ValidationError.emptyScenarioId
            }
            validatedScenarioId = validated
        } else {
            validatedScenarioId = nil
        }
        switch (validatedCampaignId, validatedScenarioId) {
        case let (.some(campaignId), .some(scenarioId)):
            self = .campaignWithStartingScenario(campaignId: campaignId, scenarioId: scenarioId)
        case let (.some(campaignId), .none):
            self = .campaignOnly(campaignId: campaignId)
        case let (.none, .some(scenarioId)):
            self = .scenarioOnly(scenarioId: scenarioId)
        case (.none, .none):
            throw ValidationError.missingCampaignOrScenario
        }
    }

    /// The wire value for the `campaignId` key: `nil` encodes as JSON `null`.
    var campaignId: String? {
        switch self {
        case let .campaignOnly(campaignId), let .campaignWithStartingScenario(campaignId, _):
            campaignId.rawValue
        case .scenarioOnly:
            nil
        }
    }

    /// The wire value for the `scenarioId` key: `nil` encodes as JSON `null`.
    var scenarioId: String? {
        switch self {
        case .campaignOnly:
            nil
        case let .campaignWithStartingScenario(_, scenarioId), let .scenarioOnly(scenarioId):
            scenarioId.rawValue
        }
    }
}
