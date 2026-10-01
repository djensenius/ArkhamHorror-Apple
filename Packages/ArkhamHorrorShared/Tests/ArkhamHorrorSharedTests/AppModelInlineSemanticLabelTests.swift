@testable import ArkhamHorrorShared
import Foundation
import Testing

extension AppModelLiveGameTests {
    @Test("Inline semantic labels render on the live AppModel prompt path")
    func inlineSemanticLabelsRenderOnLivePromptPath() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try inlineLabelEnvelope()
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let presentation = try #require(model.basicChoicePresentation(for: gameID))
        let projection = try #require(model.liveGameStates[gameID]?.lastKnownProjection)
        let inlineChoice = try #require(presentation.choices.first { $0.index == 0 })

        #expect(presentation.choiceLabelResolutions[0] == nil)
        #expect(presentation.displayTitle(for: inlineChoice, in: projection) == "Choose Skull")
        #expect(
            presentation.accessibilityLabel(for: inlineChoice, in: projection)
                == "Choose Skull"
        )
    }

    private func inlineLabelEnvelope() throws -> GetGameEnvelope {
        let data = try fixtureData(named: "get-game")
        var root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var game = try #require(root["game"] as? [String: Any])
        let playerID = try #require(root["playerId"] as? String)
        game["questionPresentation"] = [
            playerID: [
                "answer": ["kind": "singleChoice", "tag": "Answer"],
                "choiceCount": 4,
                "choices": [
                    [
                        "kind": "localizedLabel",
                        "label": ["kind": "embeddedI18n", "text": "Choose {skull}"],
                        "selectable": true,
                        "sourceIndex": 0,
                    ],
                    [
                        "actorId": "c01001",
                        "kind": "drawCard",
                        "selectable": true,
                        "sourceIndex": 1,
                    ],
                    [
                        "actorId": "c01001",
                        "kind": "endTurn",
                        "selectable": true,
                        "sourceIndex": 2,
                    ],
                    [
                        "actorId": "c01001",
                        "kind": "investigate",
                        "selectable": true,
                        "sourceIndex": 3,
                    ],
                ],
                "protocolVersion": 2,
                "questionKind": "playerWindowChooseOne",
                "questionVersion": game["scenarioSteps"] ?? 3,
            ],
        ]
        root["game"] = game
        let encoded = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return try ContractJSON.decode(GetGameEnvelope.self, from: encoded)
    }
}
