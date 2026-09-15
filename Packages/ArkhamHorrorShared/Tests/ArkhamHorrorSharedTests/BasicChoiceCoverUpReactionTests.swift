@testable import ArkhamHorrorShared
import Foundation
import Testing

enum CoverUpReactionFixtures {
    static let investigatorID = BoardTestFixtures.investigatorID("c01001")
    static let locationID = LocationID(
        // swiftlint:disable:next force_unwrapping
        UUID(uuidString: "d5a66e84-c729-4066-8475-d8a155609025")!
    )
    static let alternateLocationID = BoardTestFixtures.locationID("000000000402")
    static let skillTestID = SkillTestID(
        // swiftlint:disable:next force_unwrapping
        UUID(uuidString: "0e642a38-6354-4857-adaf-4c594641e77c")!
    )
    static let treacheryID = BoardTestFixtures.treacheryID(
        "fef723b4-ae76-4183-9441-b4f3cb8b1eb5"
    )

    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/Contract"
        ))
        return try Data(contentsOf: url)
    }

    static func value() throws -> JSONValue {
        try ContractJSON.decode(
            JSONValue.self,
            from: data("question-cover-up-reaction")
        )
    }

    static func payload(_ value: JSONValue? = nil) throws -> BasicChoiceQuestionPayload {
        try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: ContractJSON.encode(value ?? self.value())
        )
    }

    static func prompt(_ value: JSONValue? = nil) throws -> BasicChoicePromptPresentation {
        let payload = try payload(value)
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID("000000000001"),
                questionVersion: 33,
                rawQuestion: payload.rawValue,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    static func treacheryValue(
        cardCode: String = "c01007",
        clueCount: Int = 3,
        malformedTokens: Bool = false
    ) -> JSONValue {
        let tokens: JSONValue = if malformedTokens {
            .array([
                .array([
                    .string("Clue"),
                    .number(jsonNumber("1.0")),
                ]),
            ])
        } else {
            .array([
                .array([
                    .string("Clue"),
                    .number(jsonNumber(String(clueCount))),
                ]),
            ])
        }
        return .object([
            "id": .string(treacheryID.codingKey.stringValue),
            "cardCode": .string(cardCode),
            "tokens": tokens,
        ])
    }

    private static func jsonNumber(_ raw: String) -> JSONNumber {
        // swiftlint:disable:next force_try
        try! JSONNumber(exactDecimalLiteral: raw)
    }

    static func projection(
        includeInvestigator: Bool = true,
        locationID: LocationID? = Self.locationID,
        enemySpawnedLocation: Bool = false,
        includeTreachery: Bool = true,
        treacheryCardCode: String = "c01007",
        clueCount: Int = 3,
        malformedTreacheryTokens: Bool = false
    ) -> BoardProjection {
        let investigator = BoardTestFixtures.investigator(
            id: investigatorID,
            name: CardName(title: "Roland Banks", subtitle: "The Fed")
        )
        let locations: [(LocationID, Location)] = locationID.map { currentLocationID in
            let location: Location = if enemySpawnedLocation {
                .enemy(BoardTestFixtures.enemyLocation(
                    id: currentLocationID,
                    investigators: includeInvestigator ? [investigatorID] : []
                ))
            } else {
                .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: currentLocationID,
                    label: "Study",
                    investigators: includeInvestigator ? [investigatorID] : []
                ))
            }
            return [(currentLocationID, location)]
        } ?? []
        let treacheries: [TreacheryID: JSONValue] = includeTreachery
            ? [
                treacheryID: treacheryValue(
                    cardCode: treacheryCardCode,
                    clueCount: clueCount,
                    malformedTokens: malformedTreacheryTokens
                ),
            ]
            : [:]
        return BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            locations: locations,
            investigators: includeInvestigator ? [investigatorID: investigator] : [:],
            playerOrder: includeInvestigator ? [investigatorID] : [],
            treacheryValues: treacheries
        ))
    }

    static func applying(
        replacement: JSONValue,
        pointer: String,
        to value: JSONValue
    ) throws -> JSONValue {
        try EnemyAttackFixtures.applying(
            operation: "replace",
            path: pointer.split(separator: "/"),
            replacement: replacement,
            to: value
        )
    }
}

@MainActor
@Suite("Cover Up reaction parsing")
struct BasicChoiceCoverUpReactionTests {
    @Test("Reaction retains source index, identities, and opaque ability data")
    func governedReactionParsesLosslessly() throws {
        let raw = try CoverUpReactionFixtures.value()
        let payload = try CoverUpReactionFixtures.payload(raw)
        let question = try #require(payload.supportedQuestion)
        #expect(question.kind == .windowChooseOne)
        #expect(question.choices.map(\.index) == [0, 1])
        #expect(question.choices.map(\.title) == [
            "Remove 1 clue from Cover Up",
            "Skip triggers",
        ])
        #expect(question.choices[0].systemImage == "minus.circle.fill")

        guard case let .coverUpReaction(reaction) = question.choices[0].content else {
            Issue.record("Expected governed Cover Up reaction")
            return
        }
        #expect(reaction.treacheryID == CoverUpReactionFixtures.treacheryID)
        #expect(reaction.locationID == CoverUpReactionFixtures.locationID)
        #expect(reaction.skillTestID == CoverUpReactionFixtures.skillTestID)
        #expect(reaction.ability.investigatorID == CoverUpReactionFixtures.investigatorID)
        #expect(reaction.ability.cardCode.rawValue == "c01007")
        #expect(question.choices[0].ability == reaction.ability)
        #expect(try ContractJSON.decode(
            JSONValue.self, from: ContractJSON.encode(payload)
        ) == raw)
    }

    @Test("All 88 backend-published Cover Up mutations fail closed")
    func governedMutationsFailClosed() throws {
        let manifest = try ContractJSON.decode(
            JSONValue.self,
            from: CoverUpReactionFixtures.data("manifest")
        )
        guard case let .object(root) = manifest,
              case let .array(negatives)? = root["negativeFixtures"]
        else { throw TestFailure() }
        let fixturePath = JSONValue.string(
            "contracts/fixtures/question-cover-up-reaction.json"
        )
        var checked = 0
        for case let .object(entry) in negatives where entry["basePositiveFixture"] == fixturePath {
            guard case let .string(base)? = entry["basePointer"],
                  case let .object(mutation)? = entry["mutation"],
                  case let .string(pointer)? = mutation["pointer"],
                  case let .string(operation)? = mutation["op"]
            else { throw TestFailure() }
            let mutated = try EnemyAttackFixtures.applying(
                operation: operation,
                path: (base + pointer).split(separator: "/"),
                replacement: mutation["value"],
                to: CoverUpReactionFixtures.value()
            )
            let question = try CoverUpReactionFixtures.payload(mutated).supportedQuestion
            #expect(question?.choices.contains(where: {
                if case .coverUpReaction = $0.content {
                    true
                } else {
                    false
                }
            }) != true)
            checked += 1
        }
        #expect(checked == 88)
    }

    @Test("Every governed integer identity rejects noncanonical spellings")
    func numericIdentitiesMustBeCanonicalIntegers() throws {
        let pointers = [
            "/choices/0/ability/index",
            "/choices/0/ability/limit/contents/1",
            "/choices/0/ability/criteria/contents/1/contents/contents/contents",
            "/choices/0/ability/window/contents/3/contents/contents",
            "/choices/0/ability/type/window/contents/3/contents/contents",
            "/choices/0/windows/0/windowType/contents/3/contents/1",
            "/choices/0/windows/0/windowType/contents/4",
        ]
        for pointer in pointers {
            for spelling in ["1.0", "1e0", "1E+0", "-0"] {
                let mutated = try CoverUpReactionFixtures.applying(
                    replacement: .number(JSONNumber(exactDecimalLiteral: spelling)),
                    pointer: pointer,
                    to: CoverUpReactionFixtures.value()
                )
                let question = try #require(
                    CoverUpReactionFixtures.payload(mutated).supportedQuestion
                )
                #expect(!question.choices[0].isSupported)
            }
        }
    }

    @Test("A parsed reaction requires the exact Q33 root, order, and Skip identity")
    func promptShapeFailsClosed() throws {
        let canonical = try CoverUpReactionFixtures.value()
        let rootMutation = try CoverUpReactionFixtures.applying(
            replacement: .string("PlayerWindowChooseOne"),
            pointer: "/tag",
            to: canonical
        )
        #expect(try CoverUpReactionFixtures.payload(rootMutation).isUpdateRequired)

        let skipMutation = try CoverUpReactionFixtures.applying(
            replacement: .string("c01002"),
            pointer: "/choices/1/investigatorId",
            to: canonical
        )
        #expect(try CoverUpReactionFixtures.payload(skipMutation).isUpdateRequired)

        guard case var .object(root) = canonical,
              case let .array(choices)? = root["choices"]
        else { throw TestFailure() }
        root["choices"] = .array(Array(choices.reversed()))
        #expect(try CoverUpReactionFixtures.payload(.object(root)).isUpdateRequired)
    }
}

@MainActor
@Suite("Cover Up reaction fallback")
struct BasicChoiceCoverUpFallbackTests {
    @Test("Coordinated identity and action mutations cannot become Investigate")
    func malformedReactionCannotBecomeInvestigate() throws {
        let locationSource = JSONValue.object([
            "tag": .string("LocationSource"),
            "contents": .string(CoverUpReactionFixtures.locationID.codingKey.stringValue),
        ])
        let mutations: [(JSONValue, String)] = [
            (.string("c01002"), "/choices/0/investigatorId"),
            (.string("c01111"), "/choices/0/ability/cardCode"),
            (locationSource, "/choices/0/ability/source"),
            (locationSource, "/choices/0/ability/requestor"),
            (.string("GameBegins"), "/choices/0/ability/window/tag"),
            (.string("ActionAbility"), "/choices/0/ability/type/tag"),
            (.string("SingleAction"), "/choices/0/ability/type/actions/tag"),
            (.string("Investigate"), "/choices/0/ability/type/actions/contents"),
            (.string("GameBegins"), "/choices/0/windows/0/windowType/tag"),
        ]
        let mutated = try mutations.reduce(CoverUpReactionFixtures.value()) { value, mutation in
            try CoverUpReactionFixtures.applying(
                replacement: mutation.0,
                pointer: mutation.1,
                to: value
            )
        }
        let prompt = try CoverUpReactionFixtures.prompt(mutated)

        #expect(!prompt.choices[0].isSupported)
        #expect(prompt.choices[1].content == .skipTriggers(
            investigatorID: CoverUpReactionFixtures.investigatorID
        ))
        #expect(!prompt.isChoiceActionable(
            prompt.choices[0],
            in: CoverUpReactionFixtures.projection()
        ))
    }
}

@MainActor
@Suite("Cover Up reaction actionability")
struct BasicChoiceCoverUpActionabilityTests {
    @Test("Only exact current projection identities and a Cover Up clue grant authority")
    func projectionStateGatesActionability() throws {
        let prompt = try CoverUpReactionFixtures.prompt()
        let reaction = prompt.choices[0]
        #expect(prompt.isChoiceActionable(
            reaction,
            in: CoverUpReactionFixtures.projection()
        ))
        #expect(prompt.isChoiceActionable(
            reaction,
            in: CoverUpReactionFixtures.projection(enemySpawnedLocation: true)
        ))
        for projection in [
            CoverUpReactionFixtures.projection(includeInvestigator: false),
            CoverUpReactionFixtures.projection(locationID: nil),
            CoverUpReactionFixtures.projection(
                locationID: CoverUpReactionFixtures.alternateLocationID
            ),
            CoverUpReactionFixtures.projection(includeTreachery: false),
            CoverUpReactionFixtures.projection(treacheryCardCode: "c01008"),
            CoverUpReactionFixtures.projection(clueCount: 0),
            CoverUpReactionFixtures.projection(malformedTreacheryTokens: true),
        ] {
            #expect(!prompt.isChoiceActionable(reaction, in: projection))
        }
        #expect(BoardDisplayFormatting.choiceAccessibilityHint(
            for: reaction,
            in: CoverUpReactionFixtures.projection(),
            canSubmit: true,
            statusMessage: nil
        ) == "Removes 1 clue from Cover Up instead of discovering it.")
    }

    @Test("Controller focus preserves source indices and retires a stale reaction")
    func controllerRoutingUsesCurrentAuthority() throws {
        let prompt = try CoverUpReactionFixtures.prompt()
        let present = CoverUpReactionFixtures.projection()
        var submitted: [Int] = []
        let controller = BoardCommandController(
            projection: present,
            prompt: prompt,
            onChoice: { submitted.append($0) }
        )
        #expect(controller.coordinator.graph.contains(BoardFocusID.promptChoice(0)))
        #expect(controller.coordinator.graph.contains(BoardFocusID.promptChoice(1)))
        #expect(controller.handle(
            focusID: BoardFocusID.promptChoice(0),
            .command(.primaryAction)
        ))
        #expect(submitted == [0])

        controller.applySnapshot(
            CoverUpReactionFixtures.projection(clueCount: 0),
            prompt: prompt
        )
        #expect(!controller.coordinator.graph.contains(BoardFocusID.promptChoice(0)))
        #expect(controller.coordinator.graph.contains(BoardFocusID.promptChoice(1)))
        #expect(!controller.activatePromptChoice(0))
    }
}
