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
enum CampaignOrScenario: Sendable, Equatable, Hashable {
    case campaignOnly(campaignId: String)
    case campaignWithStartingScenario(campaignId: String, scenarioId: String)
    case scenarioOnly(scenarioId: String)

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
        if let campaignId, campaignId.isEmpty {
            throw ValidationError.emptyCampaignId
        }
        if let scenarioId, scenarioId.isEmpty {
            throw ValidationError.emptyScenarioId
        }
        switch (campaignId, scenarioId) {
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
            campaignId
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
            scenarioId
        }
    }
}
