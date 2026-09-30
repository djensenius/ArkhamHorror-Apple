@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("BoardPromptChoiceLinker — card entities")
struct BoardPromptChoiceLinkingTests {
    private let playerID = BoardTestFixtures.playerID("000000000801")
    private let investigatorID = BoardTestFixtures.investigatorID("c01001")

    @Test("Choice-to-board links include hand, in-play, treachery, and semantic entities")
    func choiceLinksCoverCardEntityPaths() {
        let cardID = BoardTestFixtures.cardID("000000000521")
        let assetID = BoardTestFixtures.assetID("000000000621")
        let treacheryID = BoardTestFixtures.treacheryID("00000000-0000-0000-0000-000000000721")
        let investigator = BoardTestFixtures.investigator(
            id: investigatorID,
            assets: [assetID],
            hand: [playerCard(id: cardID, code: "c01020", title: "Machete")],
            treacheries: [treacheryID],
            playerID: playerID
        )
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            investigators: [investigatorID: investigator],
            playerOrder: [investigatorID],
            activeInvestigatorID: investigatorID,
            assetValues: [assetID: assetObject(id: assetID)],
            treacheryValues: [treacheryID: treacheryObject(id: treacheryID)],
            cardValues: [cardID: playerCard(id: cardID, code: "c01020", title: "Machete")]
        ))
        let choices = cardEntityChoices(cardID: cardID, treacheryID: treacheryID)
        let semantic = semanticAssetPresentation(assetID: assetID, choices: choices)
        let links = BoardPromptChoiceLinker.links(
            prompt: prompt(choices: choices, semanticPresentation: semantic),
            projection: projection
        )

        #expect(links[.playerCard(.card(cardID))]?.map(\.choiceIndex) == [0])
        #expect(links[.treachery(treacheryID)]?.map(\.choiceIndex) == [1])
        #expect(links[.playerCard(.asset(assetID))]?.map(\.choiceIndex) == [2])
    }

    @Test("Linked board choice presentation chooses highlight, submit, or menu")
    func linkedChoicePresentationDecision() {
        let first = BoardLinkedChoice(choiceIndex: 1, title: "First", isActionable: true)
        let second = BoardLinkedChoice(choiceIndex: 2, title: "Second", isActionable: true)
        let unavailable = BoardLinkedChoice(
            choiceIndex: 3,
            title: "Unavailable",
            isActionable: false
        )

        #expect(BoardLinkedChoicePresentationPolicy.decision(for: []) == .highlightOnly)
        #expect(
            BoardLinkedChoicePresentationPolicy.decision(for: [unavailable]) == .highlightOnly
        )
        #expect(BoardLinkedChoicePresentationPolicy.decision(for: [first]) == .submit(first))
        #expect(
            BoardLinkedChoicePresentationPolicy.decision(for: [first, unavailable, second])
                == .menu([first, second])
        )
    }

    private func cardEntityChoices(
        cardID: WireCardID,
        treacheryID: TreacheryID
    ) -> [BasicChoice] {
        [
            BasicChoice(
                index: 0,
                rawValue: .string("hand"),
                content: .chooseHandCard(cardID: cardID, purpose: .choose, messages: [])
            ),
            BasicChoice(
                index: 1,
                rawValue: .string("treachery"),
                content: .resolveForcedAbility(ForcedAbilityChoice(
                    ability: ability(cardCode: "c01007"),
                    treacheryID: treacheryID
                ))
            ),
            BasicChoice(
                index: 2,
                rawValue: .string("semantic-asset"),
                content: .gainResource(investigatorID: investigatorID, messages: [])
            ),
        ]
    }

    private func semanticAssetPresentation(
        assetID: AssetID,
        choices: [BasicChoice]
    ) -> BoundQuestionPresentation {
        BoundQuestionPresentation(
            presentation: QuestionPresentation(
                protocolVersion: QuestionPresentation.supportedProtocolVersion,
                questionVersion: 1,
                questionKind: .chooseOne,
                choiceCount: choices.count,
                choices: [QuestionPresentation.Choice(
                    sourceIndex: 2,
                    kind: .useAbility,
                    actorID: investigatorID.rawValue.rawValue,
                    entity: .init(kind: .asset, id: assetID.codingKey.stringValue),
                    label: nil,
                    ability: nil,
                    cost: nil
                )]
            ),
            rawChoices: choices.map(\.rawValue),
            governedSource: nil,
            usesSealedActionabilityOverlay: false
        )
    }

    private func playerCard(id: WireCardID, code: String, title: String) -> JSONValue {
        .object([
            "tag": .string("PlayerCard"),
            "contents": .object([
                "id": .string(id.codingKey.stringValue),
                "cardCode": .string(code),
                "name": .object(["title": .string(title)]),
            ]),
        ])
    }

    private func assetObject(id: AssetID) -> JSONValue {
        .object([
            "id": .string(id.codingKey.stringValue),
            "cardId": .string(BoardTestFixtures.cardID("000000000622").codingKey.stringValue),
            "cardCode": .string("c01018"),
            "tokens": .array([.array([.string("Ammo"), number(3)])]),
        ])
    }

    private func treacheryObject(id: TreacheryID) -> JSONValue {
        .object([
            "id": .string(id.codingKey.stringValue),
            "cardCode": .string("c01007"),
            "tokens": .array([.array([.string("Clue"), number(1)])]),
        ])
    }

    private func prompt(
        choices: [BasicChoice],
        semanticPresentation: BoundQuestionPresentation? = nil
    ) -> BasicChoicePromptPresentation {
        let rawQuestion: JSONValue = .object([
            "tag": .string(BasicChoiceQuestionKind.chooseOne.rawValue),
            "choices": .array(choices.map(\.rawValue)),
        ])
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: playerID,
                questionVersion: 1,
                rawQuestion: rawQuestion,
                questionPresentation: semanticPresentation?.presentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: .supported(BasicChoiceQuestion(
                kind: .chooseOne,
                choices: choices,
                story: nil,
                rawValue: rawQuestion
            )),
            semanticPresentation: semanticPresentation,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    private func ability(cardCode: String) -> BasicChoiceAbility {
        BasicChoiceAbility(
            investigatorID: investigatorID,
            cardCode: BoardTestFixtures.cardCode(cardCode),
            rawAbility: .null,
            windows: [],
            before: [],
            messages: []
        )
    }

    private func number(_ value: Int64) -> JSONValue {
        .number(.integer(value))
    }
}
