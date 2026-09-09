@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Board mulligan choice actionability")
// swiftlint:disable:next type_body_length
struct BoardMulliganChoiceActionabilityTests {
    private func fixtureQuestion() throws -> BasicChoiceQuestion {
        let url = try #require(
            Bundle.module.url(
                forResource: "question-mulligan",
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: Data(contentsOf: url)
        )
        return try #require(payload.supportedQuestion)
    }

    private func cardID(_ raw: String) throws -> WireCardID {
        try #require(WireCardID(codingKey: AnyCodingKey(stringValue: raw)))
    }

    private func playerCard(id: WireCardID, code: String) -> JSONValue {
        .object([
            "tag": .string("PlayerCard"),
            "contents": .object([
                "id": .string(id.codingKey.stringValue),
                "owner": .string("c01001"),
                "cardCode": .string(code),
                "originalCardCode": .string(code),
                "customizations": .array([]),
                "tabooList": .null,
                "mutated": .null,
                "chained": .null,
                "meta": .null,
                "facedown": .null,
                "errata": .null,
            ]),
        ])
    }

    private func projection(
        ownerID: PlayerID,
        hand: [JSONValue],
        cards: [WireCardID: JSONValue],
        additionalInvestigators: [InvestigatorID: Investigator] = [:]
    ) -> BoardProjection {
        let ownerInvestigatorID = BoardTestFixtures.investigatorID("c01001")
        var investigators = additionalInvestigators
        investigators[ownerInvestigatorID] = BoardTestFixtures.investigator(
            id: ownerInvestigatorID,
            hand: hand,
            playerID: ownerID
        )
        return BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            investigators: investigators,
            playerOrder: [ownerInvestigatorID],
            activeInvestigatorID: ownerInvestigatorID,
            leadInvestigatorID: ownerInvestigatorID,
            cardValues: cards
        ))
    }

    @Test("Card targets resolve from one owner hand and never expose the instance UUID")
    func validHandCardResolves() throws {
        let question = try fixtureQuestion()
        let ownerID = BoardTestFixtures.playerID()
        let cardIDs = try [
            cardID("00000000-0000-0000-0000-0000000003c0"),
            cardID("00000000-0000-0000-0000-0000000003c1"),
            cardID("00000000-0000-0000-0000-0000000003c2"),
        ]
        let codes = ["c01018", "c01023", "c01030"]
        let cards = Dictionary(uniqueKeysWithValues: zip(cardIDs, codes).map {
            ($0.0, playerCard(id: $0.0, code: $0.1))
        })
        let projection = projection(
            ownerID: ownerID,
            hand: zip(cardIDs, codes).map { playerCard(id: $0.0, code: $0.1) },
            cards: cards
        )

        for (choice, code) in zip(question.choices.dropFirst(), codes) {
            #expect(projection.isChoiceActionable(
                choice,
                ownerID: ownerID,
                storyResolution: nil
            ))
            let title = BoardDisplayFormatting.choiceDisplayTitle(
                for: choice,
                in: projection,
                ownerID: ownerID
            )
            #expect(title == "Replace Card \(code)")
            #expect(!title.contains("00000000-0000-0000-0000-0000000003"))
        }
        #expect(!projection.isChoiceActionable(
            question.choices[1],
            ownerID: nil,
            storyResolution: nil
        ))
    }

    @Test("Every ownership, wrapper, ID, and card-code disagreement fails closed")
    // swiftlint:disable:next function_body_length
    func invalidHandCardAuthorityFailsClosed() throws {
        let question = try fixtureQuestion()
        let choice = question.choices[1]
        let ownerID = BoardTestFixtures.playerID()
        let otherPlayerID = try #require(PlayerID(
            codingKey: AnyCodingKey(
                stringValue: "00000000-0000-0000-0000-000000000002"
            )
        ))
        let targetID = try cardID("00000000-0000-0000-0000-0000000003c0")
        let otherID = try cardID("00000000-0000-0000-0000-0000000003c1")
        let valid = playerCard(id: targetID, code: "c01018")
        let differentID = playerCard(id: otherID, code: "c01018")
        let differentCode = playerCard(id: targetID, code: "c01019")
        let malformed: JSONValue = .object([
            "tag": .string("EncounterCard"),
            "contents": .object([
                "id": .string(targetID.codingKey.stringValue),
                "cardCode": .string("c01018"),
            ]),
        ])
        let duplicateOwnerInvestigatorID = BoardTestFixtures.investigatorID("c02001")
        let otherInvestigatorID = BoardTestFixtures.investigatorID("c03001")
        let duplicateClaimInvestigatorID = BoardTestFixtures.investigatorID("c04001")
        let ambiguousClaimInvestigatorID = BoardTestFixtures.investigatorID("c05001")
        let ambiguousClaimSiblingID = BoardTestFixtures.investigatorID("c06001")
        let mismatchedMapKey = BoardTestFixtures.investigatorID("c07001")
        let mismatchedEmbeddedID = BoardTestFixtures.investigatorID("c08001")
        let duplicatedInvestigatorID = BoardTestFixtures.investigatorID("c09001")
        let mismatchedMapProjection = BoardProjectionBuilder.makeProjection(
            from: BoardTestFixtures.snapshot(
                investigators: [
                    mismatchedMapKey: BoardTestFixtures.investigator(
                        id: mismatchedEmbeddedID,
                        hand: [valid],
                        playerID: ownerID
                    ),
                ],
                playerOrder: [mismatchedMapKey],
                activeInvestigatorID: mismatchedMapKey,
                leadInvestigatorID: mismatchedMapKey,
                cardValues: [targetID: valid]
            )
        )
        let duplicatedEmbeddedIDProjection = BoardProjectionBuilder.makeProjection(
            from: BoardTestFixtures.snapshot(
                investigators: [
                    duplicatedInvestigatorID: BoardTestFixtures.investigator(
                        id: duplicatedInvestigatorID,
                        hand: [valid],
                        playerID: ownerID
                    ),
                ],
                otherInvestigators: [
                    duplicatedInvestigatorID: BoardTestFixtures.investigator(
                        id: duplicatedInvestigatorID,
                        playerID: otherPlayerID
                    ),
                ],
                playerOrder: [duplicatedInvestigatorID],
                activeInvestigatorID: duplicatedInvestigatorID,
                leadInvestigatorID: duplicatedInvestigatorID,
                cardValues: [targetID: valid]
            )
        )
        let cases: [(String, BoardProjection)] = [
            ("missing hand", projection(ownerID: ownerID, hand: [], cards: [targetID: valid])),
            ("missing global card", projection(ownerID: ownerID, hand: [valid], cards: [:])),
            (
                "map key disagrees with embedded ID",
                projection(ownerID: ownerID, hand: [valid], cards: [targetID: differentID])
            ),
            (
                "card code disagrees",
                projection(ownerID: ownerID, hand: [valid], cards: [targetID: differentCode])
            ),
            (
                "global wrapper is not PlayerCard",
                projection(ownerID: ownerID, hand: [valid], cards: [targetID: malformed])
            ),
            (
                "duplicate target in one hand",
                projection(ownerID: ownerID, hand: [valid, valid], cards: [targetID: valid])
            ),
            (
                "two investigators map to the prompt owner",
                projection(
                    ownerID: ownerID,
                    hand: [valid],
                    cards: [targetID: valid],
                    additionalInvestigators: [
                        duplicateOwnerInvestigatorID: BoardTestFixtures.investigator(
                            id: duplicateOwnerInvestigatorID,
                            hand: [valid],
                            playerID: ownerID
                        ),
                    ]
                )
            ),
            (
                "duplicate raw claims in another player's hand",
                projection(
                    ownerID: ownerID,
                    hand: [valid],
                    cards: [targetID: valid],
                    additionalInvestigators: [
                        duplicateClaimInvestigatorID: BoardTestFixtures.investigator(
                            id: duplicateClaimInvestigatorID,
                            hand: [valid, valid],
                            playerID: otherPlayerID
                        ),
                    ]
                )
            ),
            (
                "a claim from an ambiguous player's investigators",
                projection(
                    ownerID: ownerID,
                    hand: [valid],
                    cards: [targetID: valid],
                    additionalInvestigators: [
                        ambiguousClaimInvestigatorID: BoardTestFixtures.investigator(
                            id: ambiguousClaimInvestigatorID,
                            hand: [valid],
                            playerID: otherPlayerID
                        ),
                        ambiguousClaimSiblingID: BoardTestFixtures.investigator(
                            id: ambiguousClaimSiblingID,
                            playerID: otherPlayerID
                        ),
                    ]
                )
            ),
            (
                "two players claim the same card",
                projection(
                    ownerID: ownerID,
                    hand: [valid],
                    cards: [targetID: valid],
                    additionalInvestigators: [
                        otherInvestigatorID: BoardTestFixtures.investigator(
                            id: otherInvestigatorID,
                            hand: [valid],
                            playerID: otherPlayerID
                        ),
                    ]
                )
            ),
            ("investigator map key disagrees with embedded ID", mismatchedMapProjection),
            ("investigator ID appears in multiple maps", duplicatedEmbeddedIDProjection),
        ]

        for (name, projection) in cases {
            #expect(
                !projection.isChoiceActionable(
                    choice,
                    ownerID: ownerID,
                    storyResolution: nil
                ),
                Comment(rawValue: name)
            )
            let title = BoardDisplayFormatting.choiceDisplayTitle(
                for: choice,
                in: projection,
                ownerID: ownerID
            )
            #expect(title == "Unavailable card (choice 2)", Comment(rawValue: name))
            #expect(!title.contains(targetID.codingKey.stringValue), Comment(rawValue: name))
        }
    }

    @Test("An unavailable done label disables only source index zero")
    // swiftlint:disable:next function_body_length
    func unavailableDoneLabelDoesNotDisableCards() throws {
        let question = try fixtureQuestion()
        let ownerID = BoardTestFixtures.playerID()
        let targetID = try cardID("00000000-0000-0000-0000-0000000003c0")
        let valid = playerCard(id: targetID, code: "c01018")
        let projection = projection(
            ownerID: ownerID,
            hand: [valid],
            cards: [targetID: valid]
        )
        let identity = BasicChoicePromptIdentity(
            gameID: BoardTestFixtures.gameID(),
            ownerID: ownerID,
            questionVersion: 4,
            rawQuestion: question.rawValue,
            sessionAttemptID: nil,
            connectionID: nil
        )
        let unavailable = BasicChoicePromptPresentation(
            identity: identity,
            question: .supported(question),
            choiceLabelResolutions: [0: .unavailable(.missingKey)],
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
        #expect(!unavailable.isChoiceActionable(question.choices[0], in: projection))
        #expect(unavailable.isChoiceActionable(question.choices[1], in: projection))
        #expect(BoardDisplayFormatting.choiceDisplayTitle(
            for: question.choices[0],
            in: projection,
            ownerID: ownerID,
            labelResolution: unavailable.choiceLabelResolutions[0]
        ) == "Unavailable action (choice 1)")
        #expect(BoardDisplayFormatting.choiceAccessibilityHint(
            for: question.choices[0],
            in: projection,
            ownerID: ownerID,
            storyResolution: nil,
            labelResolution: unavailable.choiceLabelResolutions[0],
            canSubmit: unavailable.canSubmit,
            statusMessage: unavailable.statusMessage
        ) == "This server publishes no usable text for this choice.")

        let resolved = BasicChoicePromptPresentation(
            identity: identity,
            question: .supported(question),
            choiceLabelResolutions: [0: .resolved("Done replacing cards")],
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
        #expect(resolved.isChoiceActionable(question.choices[0], in: projection))
        #expect(BoardDisplayFormatting.choiceDisplayTitle(
            for: question.choices[0],
            in: projection,
            ownerID: ownerID,
            labelResolution: resolved.choiceLabelResolutions[0]
        ) == "Done replacing cards")
    }
}
