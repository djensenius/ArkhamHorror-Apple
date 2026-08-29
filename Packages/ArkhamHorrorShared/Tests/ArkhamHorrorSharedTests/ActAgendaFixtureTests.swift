@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Focused governed-fixture coverage for `Act.advanceCost`'s object/null field and the
/// closed `A`-`H`/`A`-`D` act/agenda side domains.
@Suite("Act/Agenda fixture decode")
struct ActAgendaFixtureTests {
    private func fixtureData(named fileName: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: fileName,
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try Data(contentsOf: url)
    }

    @Test("An act with a null advanceCost decodes advanceCost to nil")
    func actWithNoAdvanceCostDecodes() throws {
        let act = try ContractJSON.decode(Act.self, from: fixtureData(named: "act-no-advance-cost"))
        #expect(act.advanceCost == nil)
        #expect(act.sequence == ActSequence(step: 2, side: .sideA))
        #expect(try act.id == ActID(CardCode("c90014")))
        #expect(act.breaches == .null)
    }

    @Test("An act's advanceCost, when present, preserves its nested contents losslessly")
    func actWithAdvanceCostPreservesNestedContents() throws {
        let envelope = try ContractJSON.decode(
            GetGameEnvelope.self, from: fixtureData(named: "get-game")
        )
        let actID = try ActID(CardCode("c01108"))
        let act = try #require(envelope.game.acts[actID])
        let cost = try #require(act.advanceCost)
        #expect(cost.tag == "GroupClueCost")
        guard case let .array(contents)? = cost.contents, contents.count == 2 else {
            Issue.record("Expected a 2-element GroupClueCost contents array")
            return
        }
        guard case let .object(perPlayer) = contents[0] else {
            Issue.record("Expected the first element to be a GameValue-shaped object")
            return
        }
        #expect(perPlayer["tag"] == .string("PerPlayer"))
    }

    @Test("ActSequence requires exactly 2 elements, rejecting a 3-element array")
    func actSequenceRejectsWrongArity() throws {
        let bytes = Data(#"[1, "A", "extra"]"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try ContractJSON.decode(ActSequence.self, from: bytes)
        }
    }

    @Test("An ActSequence side value of the wrong type fails to decode")
    func actSequenceWithNonStringSideFails() throws {
        let bytes = Data(#"[1, 5]"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try ContractJSON.decode(ActSequence.self, from: bytes)
        }
    }

    @Test("An unrecognized-but-well-formed act side string still decodes losslessly")
    func unrecognizedActSideStillDecodes() throws {
        let bytes = Data(#"[1, "Z"]"#.utf8)
        let sequence = try ContractJSON.decode(ActSequence.self, from: bytes)
        #expect(sequence.side.rawValue == "Z")
    }

    @Test("AgendaSequence requires both agendaSequenceSide and agendaSequenceStep keys")
    func agendaSequenceMissingRequiredKeyFails() throws {
        let bytes = Data(#"{"agendaSequenceSide": "A"}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try ContractJSON.decode(AgendaSequence.self, from: bytes)
        }
    }

    @Test("An agenda's doomThreshold decodes as a GameValue")
    func agendaDoomThresholdDecodes() throws {
        let envelope = try ContractJSON.decode(
            GetGameEnvelope.self, from: fixtureData(named: "get-game")
        )
        let agendaID = try AgendaID(CardCode("c01105"))
        let agenda = try #require(envelope.game.agendas[agendaID])
        #expect(agenda.doomThreshold == .staticValue(3))
        #expect(agenda.doom == 0)
    }
}
