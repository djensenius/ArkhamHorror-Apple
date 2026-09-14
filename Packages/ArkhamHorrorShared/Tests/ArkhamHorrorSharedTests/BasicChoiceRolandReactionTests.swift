@testable import ArkhamHorrorShared
import Foundation
import Testing

enum RolandReactionFixtures {
    static let investigatorID = BoardTestFixtures.investigatorID("c01001")
    static let locationID = BoardTestFixtures.locationID("000000000401")
    // swiftlint:disable:next force_unwrapping
    static let enemyID = EnemyID(UUID(uuidString: "6420b429-88f1-44b2-9a51-e5eb8ae44598")!)

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
            from: data("question-roland-defeat-reaction")
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
                questionVersion: 32,
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

    static func projection(
        includeInvestigator: Bool = true,
        placeInvestigator: Bool = true,
        enemySpawnedLocation: Bool = false
    ) -> BoardProjection {
        let investigator = BoardTestFixtures.investigator(
            id: investigatorID,
            name: CardName(title: "Roland Banks", subtitle: "The Fed")
        )
        let occupants = placeInvestigator && includeInvestigator ? [investigatorID] : []
        let location: Location = if enemySpawnedLocation {
            .enemy(BoardTestFixtures.enemyLocation(
                id: locationID,
                investigators: occupants
            ))
        } else {
            .ordinary(BoardTestFixtures.ordinaryLocation(
                id: locationID,
                label: "Study",
                investigators: occupants
            ))
        }
        return BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            locations: [(locationID, location)],
            investigators: includeInvestigator ? [investigatorID: investigator] : [:],
            playerOrder: includeInvestigator ? [investigatorID] : []
        ))
    }
}

@MainActor
@Suite("Roland Banks post-defeat reaction")
struct BasicChoiceRolandReactionTests {
    @Test("Reaction retains its source index, identities, and opaque ability data")
    func governedReactionParsesLosslessly() throws {
        let raw = try RolandReactionFixtures.value()
        let payload = try RolandReactionFixtures.payload(raw)
        let question = try #require(payload.supportedQuestion)
        #expect(question.kind == .windowChooseOne)
        #expect(question.choices.map(\.index) == [0, 1])
        #expect(question.choices.map(\.title) == ["Discover 1 clue", "Skip triggers"])
        #expect(question.choices[0].systemImage == "magnifyingglass.circle.fill")

        guard case let .rolandDefeatReaction(reaction) = question.choices[0].content
        else {
            Issue.record("Expected governed Roland reaction")
            return
        }
        #expect(reaction.defeatedEnemyID == RolandReactionFixtures.enemyID)
        #expect(reaction.ability.investigatorID == RolandReactionFixtures.investigatorID)
        #expect(reaction.ability.cardCode.rawValue == "c01001")
        #expect(reaction.ability.windows.count == 1)
        #expect(reaction.ability.before.isEmpty)
        #expect(reaction.ability.messages.isEmpty)
        #expect(question.choices[0].ability == reaction.ability)
        #expect(try ContractJSON.decode(
            JSONValue.self, from: ContractJSON.encode(payload)
        ) == raw)
    }

    @Test("Malformed reaction remains visible but cannot gain answer authority")
    func malformedReactionFailsClosedWithoutHidingSkip() throws {
        let canonical = try RolandReactionFixtures.value()
        let mutations = try [
            RolandMutation(
                replacement: .string("ActionAbility"),
                pointer: "/choices/0/ability/type/tag"
            ),
            RolandMutation(
                replacement: .number(.integer(2)),
                pointer: "/choices/0/ability/index"
            ),
            RolandMutation(
                replacement: .number(JSONNumber(exactDecimalLiteral: "1.0")),
                pointer: "/choices/0/ability/index"
            ),
            RolandMutation(
                replacement: .number(JSONNumber(exactDecimalLiteral: "1e0")),
                pointer: "/choices/0/ability/limit/contents/1"
            ),
            RolandMutation(
                replacement: .string("c01002"),
                pointer: "/choices/0/investigatorId"
            ),
            RolandMutation(
                replacement: .string("6420b429-88f1-44b2-9a51-e5eb8ae44599"),
                pointer: "/choices/0/windows/0/windowType/contents/2"
            ),
        ]
        for mutation in mutations {
            let mutated = try applying(mutation, to: canonical)
            let question = try #require(
                RolandReactionFixtures.payload(mutated).supportedQuestion
            )
            #expect(!question.choices[0].isSupported)
            #expect(question.choices[0].title == "Update required")
            #expect(question.choices[1].content == .skipTriggers(
                investigatorID: RolandReactionFixtures.investigatorID
            ))
        }
    }

    @Test("All 60 backend-published Roland mutations fail closed")
    func governedMutationsFailClosed() throws {
        let manifest = try ContractJSON.decode(
            JSONValue.self,
            from: RolandReactionFixtures.data("manifest")
        )
        guard case let .object(root) = manifest,
              case let .array(negatives)? = root["negativeFixtures"]
        else { throw TestFailure() }
        let fixturePath = JSONValue.string(
            "contracts/fixtures/question-roland-defeat-reaction.json"
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
                to: RolandReactionFixtures.value()
            )
            let payload = try RolandReactionFixtures.payload(mutated)
            if let question = payload.supportedQuestion {
                #expect(!question.choices.contains { choice in
                    if case .rolandDefeatReaction = choice.content {
                        true
                    } else {
                        false
                    }
                })
            }
            checked += 1
        }
        #expect(checked == 60)
    }

    @Test("Every governed integer identity rejects noncanonical spellings")
    func numericIdentitiesMustBeCanonicalIntegers() throws {
        let cases: [(String, [String])] = [
            (
                "/choices/0/ability/index",
                ["1.0", "1e0", "1E+0", "-0"]
            ),
            (
                "/choices/0/ability/limit/contents/1",
                ["1.0", "1e0", "1E+0", "-0"]
            ),
            (
                "/choices/0/windows/0/windowType/contents/1/contents/contents/2",
                ["100.0", "1e2", "1E+2"]
            ),
        ]
        for (pointer, spellings) in cases {
            for spelling in spellings {
                let mutated = try applying(
                    RolandMutation(
                        replacement: .number(JSONNumber(
                            exactDecimalLiteral: spelling
                        )),
                        pointer: pointer
                    ),
                    to: RolandReactionFixtures.value()
                )
                let question = try #require(
                    RolandReactionFixtures.payload(mutated).supportedQuestion
                )
                #expect(!question.choices[0].isSupported)
            }
        }
    }

    @Test("A parsed reaction requires the exact Q32 root, order, and Skip identity")
    func promptShapeFailsClosed() throws {
        let canonical = try RolandReactionFixtures.value()
        let rootMutation = try applying(
            RolandMutation(
                replacement: .string("PlayerWindowChooseOne"),
                pointer: "/tag"
            ),
            to: canonical
        )
        #expect(try RolandReactionFixtures.payload(rootMutation).isUpdateRequired)

        let skipMutation = try applying(
            RolandMutation(
                replacement: .string("c01002"),
                pointer: "/choices/1/contents"
            ),
            to: canonical
        )
        #expect(try RolandReactionFixtures.payload(skipMutation).isUpdateRequired)

        guard case var .object(root) = canonical,
              case let .array(choices)? = root["choices"]
        else { throw TestFailure() }
        root["choices"] = .array(Array(choices.reversed()))
        #expect(try RolandReactionFixtures.payload(.object(root)).isUpdateRequired)
    }

    @Test("Roland and his current location alone control native actionability")
    func currentLocationControlsActionabilityAndRouting() throws {
        let prompt = try RolandReactionFixtures.prompt()
        let reaction = prompt.choices[0]
        let present = RolandReactionFixtures.projection()
        let enemyLocation = RolandReactionFixtures.projection(enemySpawnedLocation: true)
        let missingInvestigator = RolandReactionFixtures.projection(includeInvestigator: false)
        let missingLocation = RolandReactionFixtures.projection(placeInvestigator: false)

        #expect(prompt.isChoiceActionable(reaction, in: present))
        #expect(prompt.isChoiceActionable(reaction, in: enemyLocation))
        #expect(!prompt.isChoiceActionable(reaction, in: missingInvestigator))
        #expect(!prompt.isChoiceActionable(reaction, in: missingLocation))
        #expect(BoardDisplayFormatting.choiceDisplayTitle(
            for: reaction, in: present
        ) == "Discover 1 clue")
        #expect(BoardDisplayFormatting.choiceAccessibilityHint(
            for: reaction,
            in: missingLocation,
            canSubmit: true,
            statusMessage: nil
        ) == "Roland Banks or his location isn't currently available.")

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

        controller.applySnapshot(missingLocation, prompt: prompt)
        #expect(!controller.coordinator.graph.contains(BoardFocusID.promptChoice(0)))
        #expect(controller.coordinator.graph.contains(BoardFocusID.promptChoice(1)))
        #expect(!controller.activatePromptChoice(0))
    }

    private struct RolandMutation {
        let replacement: JSONValue
        let pointer: String
    }

    private func applying(
        _ mutation: RolandMutation,
        to value: JSONValue
    ) throws -> JSONValue {
        try EnemyAttackFixtures.applying(
            operation: "replace",
            path: mutation.pointer.split(separator: "/"),
            replacement: mutation.replacement,
            to: value
        )
    }
}

@MainActor
@Suite("Roland Banks reaction fallback")
struct BasicChoiceRolandFallbackTests {
    @Test("Malformed Roland reaction cannot fall through as a generic action")
    func malformedReactionCannotBecomeInvestigate() throws {
        let locationSource = JSONValue.object([
            "tag": .string("LocationSource"),
            "contents": .string(RolandReactionFixtures.locationID.codingKey.stringValue),
        ])
        let mutations: [(JSONValue, String)] = [
            (.string("c01111"), "/choices/0/ability/cardCode"),
            (locationSource, "/choices/0/ability/source"),
            (locationSource, "/choices/0/ability/requestor"),
            (.string("ActionAbility"), "/choices/0/ability/type/tag"),
            (.string("SingleAction"), "/choices/0/ability/type/actions/tag"),
            (.string("Investigate"), "/choices/0/ability/type/actions/contents"),
        ]
        let mutated = try mutations.reduce(RolandReactionFixtures.value()) { value, mutation in
            try EnemyAttackFixtures.applying(
                operation: "replace",
                path: mutation.1.split(separator: "/"),
                replacement: mutation.0,
                to: value
            )
        }
        let prompt = try RolandReactionFixtures.prompt(mutated)

        #expect(!prompt.choices[0].isSupported)
        #expect(prompt.choices[0].title == "Update required")
        #expect(prompt.choices[1].content == .skipTriggers(
            investigatorID: RolandReactionFixtures.investigatorID
        ))
        #expect(!prompt.isChoiceActionable(
            prompt.choices[0],
            in: RolandReactionFixtures.projection()
        ))
    }
}
