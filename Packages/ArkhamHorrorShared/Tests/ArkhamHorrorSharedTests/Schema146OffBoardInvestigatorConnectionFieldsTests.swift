@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Schema 0.1.46 off-board investigator connection fields")
struct Schema146OffBoardConnectionTests {
    @Test("off-board investigators tolerate absent connection-scoped fields only")
    func offBoardInvestigatorsDecodeWithoutConnectionFields() throws {
        for collection in schema146OffBoardInvestigatorCollections {
            let value = try schema146GetGameWithOffBoardInvestigator(
                collection: collection,
                handSize: .absent,
                scarletKeys: .absent
            )
            let envelope = try decodeSchema146GetGame(value)
            let investigator = try schema146OffBoardInvestigator(
                in: envelope,
                collection: collection
            )
            let decoded = try #require(investigator)
            let rolandID = try InvestigatorID(CardCode("c01001"))
            #expect(decoded.handSize == nil)
            #expect(decoded.scarletKeys.isEmpty)
            #expect(envelope.game.investigators[rolandID]?.handSize == 8)
        }
    }

    @Test("off-board investigator null connection-scoped fields fail only that entry")
    func offBoardInvestigatorNullConnectionFieldsFailEntry() throws {
        for collection in schema146OffBoardInvestigatorCollections {
            for field in ["handSize", "scarletKeys"] {
                let value = try schema146GetGameWithOffBoardInvestigator(
                    collection: collection,
                    handSize: field == "handSize" ? .present(.null) : .absent,
                    scarletKeys: field == "scarletKeys" ? .present(.null) : .absent
                )
                let envelope = try decodeSchema146GetGame(value)
                let investigator = try schema146OffBoardInvestigator(
                    in: envelope,
                    collection: collection
                )
                let rolandID = try InvestigatorID(CardCode("c01001"))
                #expect(investigator == nil)
                #expect(envelope.game.investigators[rolandID]?.handSize == 8)
            }
        }
    }

    @Test("off-board investigator wrong-type connection fields fail only that entry")
    func offBoardInvestigatorWrongTypeConnectionFieldsFailEntry() throws {
        for collection in schema146OffBoardInvestigatorCollections {
            for field in ["handSize", "scarletKeys"] {
                let value = try schema146GetGameWithOffBoardInvestigator(
                    collection: collection,
                    handSize: field == "handSize" ? .present(.string("6")) : .absent,
                    scarletKeys: field == "scarletKeys" ? .present(.string("c04001")) : .absent
                )
                let envelope = try decodeSchema146GetGame(value)
                let investigator = try schema146OffBoardInvestigator(
                    in: envelope,
                    collection: collection
                )
                let rolandID = try InvestigatorID(CardCode("c01001"))
                #expect(investigator == nil)
                #expect(envelope.game.investigators[rolandID]?.handSize == 8)
            }
        }
    }
}

private enum Schema146ConnectionFieldValue {
    case absent
    case present(JSONValue)
}

private let schema146OffBoardInvestigatorCollections = [
    "killedInvestigators",
    "otherInvestigators",
    "retiredInvestigators",
]

private func schema146GetGameWithOffBoardInvestigator(
    collection: String,
    handSize: Schema146ConnectionFieldValue,
    scarletKeys: Schema146ConnectionFieldValue
) throws -> JSONValue {
    let value = try schema146FixtureValue("get-game")
    guard case var .object(root) = value,
          case var .object(game)? = root["game"],
          case let .object(investigators)? = game["investigators"],
          case var .object(investigator)? = investigators["c01001"]
    else { throw TestFailure() }

    investigator["id"] = .string("c01002")
    investigator["cardCode"] = .string("c01002")
    switch handSize {
    case .absent:
        investigator.removeValue(forKey: "handSize")
    case let .present(value):
        investigator["handSize"] = value
    }
    switch scarletKeys {
    case .absent:
        investigator.removeValue(forKey: "scarletKeys")
    case let .present(value):
        investigator["scarletKeys"] = value
    }
    game[collection] = .object(["c01002": .object(investigator)])
    root["game"] = .object(game)
    return .object(root)
}

private func schema146OffBoardInvestigator(
    in envelope: GetGameEnvelope,
    collection: String
) throws -> Investigator? {
    let investigatorID = try InvestigatorID(CardCode("c01002"))
    switch collection {
    case "killedInvestigators":
        return envelope.game.killedInvestigators[investigatorID]
    case "otherInvestigators":
        return envelope.game.otherInvestigators[investigatorID]
    case "retiredInvestigators":
        return envelope.game.retiredInvestigators?[investigatorID]
    default:
        throw TestFailure()
    }
}

private func decodeSchema146GetGame(_ value: JSONValue) throws -> GetGameEnvelope {
    try ContractJSON.decode(GetGameEnvelope.self, from: ContractJSON.encode(value))
}

private func schema146FixtureValue(_ name: String) throws -> JSONValue {
    try ContractJSON.decode(JSONValue.self, from: schema146FixtureData(name))
}

private func schema146FixtureData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(
        forResource: name,
        withExtension: "json",
        subdirectory: "Fixtures/Contract"
    ))
    return try Data(contentsOf: url)
}
