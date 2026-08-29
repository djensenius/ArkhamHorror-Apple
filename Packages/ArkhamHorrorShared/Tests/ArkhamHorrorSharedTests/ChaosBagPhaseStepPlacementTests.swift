@testable import ArkhamHorrorShared
import Foundation
import Testing

/// A minimal manual-`Decodable` wrapper for exercising `PhaseStep?` in isolation:
/// `PhaseStep` itself intentionally has no `Decodable` conformance of its own (only
/// the free ``NullablePhaseStep`` decode/encode pair, mirroring how
/// `PublicGameSnapshot`'s own manual `init(from:)` decodes its `phaseStep` field via
/// `superDecoder(forKey:)`), so a synthesized `Decodable` on a struct that merely
/// stores a `PhaseStep?` would not compile.
private struct PhaseStepWrapper: Decodable {
    let phaseStep: PhaseStep?

    private enum CodingKeys: String, CodingKey { case phaseStep }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        phaseStep = try NullablePhaseStep.decode(
            from: container.superDecoder(forKey: .phaseStep)
        )
    }
}

/// Coverage for the smaller governed shapes this contract slice models: `ChaosBag`/
/// `ChaosToken`, `PhaseStep`, `Placement`, and `RuntimeCost`.
@Suite("Chaos bag / phase step / placement / cost")
struct ChaosBagPhaseStepPlacementTests {
    @Test("A ChaosToken's required-nullable chaosTokenRevealedBy decodes null and a value")
    func chaosTokenRevealedByDecodesBothStates() throws {
        let nullBytes = Data(
            """
            {"chaosTokenId": "00000000-0000-0000-0000-000000000001", "chaosTokenFace": "Skull",
             "chaosTokenRevealedBy": null, "chaosTokenCancelled": false, "chaosTokenSealed": false}
            """.utf8
        )
        let nullToken = try ContractJSON.decode(ChaosToken.self, from: nullBytes)
        #expect(nullToken.chaosTokenRevealedBy == nil)
        #expect(nullToken.chaosTokenFace == .skull)

        let valueBytes = Data(
            """
            {"chaosTokenId": "00000000-0000-0000-0000-000000000001", "chaosTokenFace": "Skull",
             "chaosTokenRevealedBy": "c01001", "chaosTokenCancelled": false, \
             "chaosTokenSealed": false}
            """.utf8
        )
        let valueToken = try ContractJSON.decode(ChaosToken.self, from: valueBytes)
        #expect(valueToken.chaosTokenRevealedBy?.rawValue.rawValue == "c01001")
    }

    @Test("An unrecognized (homebrew) chaos token face decodes losslessly")
    func homebrewChaosTokenFaceDecodes() throws {
        let bytes = Data(
            """
            {"chaosTokenId": "00000000-0000-0000-0000-000000000001", \
             "chaosTokenFace": ":circus-ex-mortis:moon", "chaosTokenRevealedBy": null, \
             "chaosTokenCancelled": false, "chaosTokenSealed": false}
            """.utf8
        )
        let token = try ContractJSON.decode(ChaosToken.self, from: bytes)
        #expect(token.chaosTokenFace.rawValue == ":circus-ex-mortis:moon")
    }

    @Test("PhaseStep decodes null and each of the 4 governed outer tags")
    func phaseStepDecodesNullAndEachOuterTag() throws {
        func decode(_ json: String) throws -> PhaseStep? {
            let bytes = Data("{\"phaseStep\": \(json)}".utf8)
            return try ContractJSON.decode(PhaseStepWrapper.self, from: bytes).phaseStep
        }
        #expect(try decode("null") == nil)
        #expect(
            try decode(#"{"tag": "MythosPhaseStep", "contents": "MythosPhaseBeginsStep"}"#)
                == .mythos(.mythosPhaseBegins)
        )
        #expect(
            try decode(
                #"{"tag": "InvestigationPhaseStep", "contents": "InvestigatorTakesActionStep"}"#
            )
                == .investigation(.investigatorTakesAction)
        )
        #expect(
            try decode(#"{"tag": "EnemyPhaseStep", "contents": "ResolveAttacksStep"}"#)
                == .enemy(.resolveAttacks)
        )
        #expect(
            try decode(#"{"tag": "UpkeepPhaseStep", "contents": "CheckHandSizeStep"}"#)
                == .upkeep(.checkHandSize)
        )
    }

    @Test("An unrecognized top-level PhaseStep tag decodes losslessly as .unknown")
    func unknownPhaseStepTagPreservesRawObject() throws {
        let bytes = Data(#"{"phaseStep": {"tag": "ResolutionPhaseStep", "contents": "X"}}"#.utf8)
        let phaseStep = try ContractJSON.decode(PhaseStepWrapper.self, from: bytes).phaseStep
        guard case let .unknown(tag, _) = phaseStep else {
            Issue.record("Expected .unknown")
            return
        }
        #expect(tag == "ResolutionPhaseStep")
    }

    @Test("Placement preserves the tri-state absent/null/value contents distinction")
    func placementContentsTriState() throws {
        let absent = try ContractJSON.decode(
            Placement.self, from: Data(#"{"tag": "Unplaced"}"#.utf8)
        )
        #expect(absent.contents == .absent)

        let nullValue = try ContractJSON.decode(
            Placement.self, from: Data(#"{"tag": "Unplaced", "contents": null}"#.utf8)
        )
        #expect(nullValue.contents == .null)

        let presentContentsID = "00000000-0000-0000-0000-000000000001"
        let present = try ContractJSON.decode(
            Placement.self,
            from: Data(#"{"tag": "AtLocation", "contents": "\#(presentContentsID)"}"#.utf8)
        )
        #expect(present.contents == .value(.string(presentContentsID)))
    }

    @Test("RuntimeCost preserves an arbitrary open tag and nested contents")
    func runtimeCostPreservesOpenTagAndContents() throws {
        let cost = try ContractJSON.decode(
            RuntimeCost.self, from: Data(#"{"tag": "SomeFutureCostConstructor"}"#.utf8)
        )
        #expect(cost.tag == "SomeFutureCostConstructor")
        #expect(cost.contents == nil)
    }

    @Test("An unexpected extra key on RuntimeCost is ignored, not fatal or mis-attributed")
    func runtimeCostIgnoresAdditionalProperties() throws {
        // RuntimeCost's CodingKeys enumerates only tag/contents; an unknown extra key is
        // simply never read here (this type's Codable implementation, like every other
        // response type in this contract slice, does not itself enforce closed keys —
        // matching this codebase's established forward-compatible convention, even though
        // the backend's own cost.schema.json declares this envelope closed at the schema
        // level). This test documents that decoding still succeeds rather than silently
        // mis-attributing an extra key to `contents`.
        let cost = try ContractJSON.decode(
            RuntimeCost.self,
            from: Data(#"{"tag": "Free", "unexpectedExtraKey": 1}"#.utf8)
        )
        #expect(cost.tag == "Free")
        #expect(cost.contents == nil)
    }
}
