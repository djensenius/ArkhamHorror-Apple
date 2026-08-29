@testable import ArkhamHorrorShared
import Foundation
import Testing

/// A minimal, otherwise-valid `CreateGameRequest` wire payload with the `campaignId`/
/// `scenarioId` region left as two independently-substitutable fragments, so decode-time
/// invariant tests can exercise every presence/null/absent combination against real JSON
/// bytes (not just the constructor) without repeating the rest of the required fields.
///
/// `campaignField`/`scenarioField` must each be either `""` (the key entirely absent) or a
/// complete, comma-terminated `"key":value,` fragment.
private func makeCreateGameRequestBytes(
    campaignField: String,
    scenarioField: String
) -> Data {
    Data(
        """
        {"deckIds":[],"playerCount":1,\(campaignField)\(scenarioField)\
        "difficulty":"Easy","campaignName":"Test","multiplayerVariant":"Solo",\
        "includeTarotReadings":false,"options":[]}
        """.utf8
    )
}

/// The `campaignId`/`scenarioId` invariant, exercised against raw wire bytes rather than
/// the Swift constructor (see ``GameLifecycleTests`` for the construction-time half of
/// this coverage), so a regression that re-opened a decode-only bypass (e.g. reverting to
/// two independent `decodeIfPresent`s instead of routing through `CampaignOrScenario.init`)
/// would be caught even if the constructor path were still correct. Split into its own
/// file purely to stay under SwiftLint's file/type-length limits.
@Suite("GameLifecycle campaign/scenario invariant (decode time)")
struct CampaignOrScenarioDecodeInvariantTests {
    @Test("Decoding succeeds with both campaignId and scenarioId present")
    func decodeBothPresentSucceeds() throws {
        let request = try ContractJSON.decode(
            CreateGameRequest.self,
            from: makeCreateGameRequestBytes(
                campaignField: #""campaignId":"01","#,
                scenarioField: #""scenarioId":"01104","#
            )
        )
        #expect(request.campaignOrScenario == .campaignWithStartingScenario(
            campaignId: "01",
            scenarioId: "01104"
        ))
    }

    @Test("Decoding succeeds with campaignId present and scenarioId explicit null")
    func decodeCampaignOnlyExplicitNullSucceeds() throws {
        let request = try ContractJSON.decode(
            CreateGameRequest.self,
            from: makeCreateGameRequestBytes(
                campaignField: #""campaignId":"01","#,
                scenarioField: #""scenarioId":null,"#
            )
        )
        #expect(request.campaignOrScenario == .campaignOnly(campaignId: "01"))
    }

    @Test("Decoding succeeds with scenarioId present and campaignId key entirely absent")
    func decodeScenarioOnlyAbsentKeySucceeds() throws {
        let request = try ContractJSON.decode(
            CreateGameRequest.self,
            from: makeCreateGameRequestBytes(
                campaignField: "",
                scenarioField: #""scenarioId":"01104","#
            )
        )
        #expect(request.campaignOrScenario == .scenarioOnly(scenarioId: "01104"))
    }

    @Test("Decoding throws when both campaignId and scenarioId are explicit null")
    func decodeBothNullThrows() {
        #expect(throws: CampaignOrScenario.ValidationError.missingCampaignOrScenario) {
            try ContractJSON.decode(
                CreateGameRequest.self,
                from: makeCreateGameRequestBytes(
                    campaignField: #""campaignId":null,"#,
                    scenarioField: #""scenarioId":null,"#
                )
            )
        }
    }

    @Test("Decoding throws when both campaignId and scenarioId keys are absent")
    func decodeBothAbsentThrows() {
        #expect(throws: CampaignOrScenario.ValidationError.missingCampaignOrScenario) {
            try ContractJSON.decode(
                CreateGameRequest.self,
                from: makeCreateGameRequestBytes(campaignField: "", scenarioField: "")
            )
        }
    }

    @Test("Decoding throws when campaignId is an empty string")
    func decodeEmptyCampaignIdThrows() {
        #expect(throws: CampaignOrScenario.ValidationError.emptyCampaignId) {
            try ContractJSON.decode(
                CreateGameRequest.self,
                from: makeCreateGameRequestBytes(
                    campaignField: #""campaignId":"","#,
                    scenarioField: #""scenarioId":null,"#
                )
            )
        }
    }

    @Test("Decoding throws when scenarioId is an empty string")
    func decodeEmptyScenarioIdThrows() {
        #expect(throws: CampaignOrScenario.ValidationError.emptyScenarioId) {
            try ContractJSON.decode(
                CreateGameRequest.self,
                from: makeCreateGameRequestBytes(
                    campaignField: #""campaignId":null,"#,
                    scenarioField: #""scenarioId":"","#
                )
            )
        }
    }
}
