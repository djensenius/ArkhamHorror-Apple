@testable import ArkhamHorrorShared
import Foundation
import Testing

extension QuestionPresentationTests {
    @Test("Recursive cost and amount shapes decode and round-trip exactly")
    func recursiveCostsRoundTrip() throws {
        let presentation = try ContractJSON.decode(
            QuestionPresentation.self,
            from: Data(recursiveCostJSON.utf8)
        )
        #expect(presentation.choices.first?.cost == recursiveCost)
        #expect(
            try ContractJSON.decode(
                QuestionPresentation.self,
                from: ContractJSON.encode(presentation)
            ) == presentation
        )
    }

    private var recursiveCost: QuestionPresentation.Cost {
        .all([
            .action(1),
            .choice([
                .resource(2),
                .groupResource(
                    amount: .fixedPlusPerPlayer(fixed: 1, perPlayer: 2),
                    scope: .sameLocation
                ),
            ]),
            .clue(.byPlayerCount([1, 2, 3, 4])),
            .clue(.variable),
            .clue(.star),
            .clue(.unknown),
            .other,
        ])
    }

    private var recursiveCostJSON: String {
        """
        {
          "protocolVersion": 1,
          "questionVersion": 1,
          "questionKind": "chooseOne",
          "choiceCount": 1,
          "choices": [{
            "sourceIndex": 0,
            "kind": "useAbility",
            "actorId": "c01001",
            "ability": {
              "cardCode": "c01001",
              "index": 1,
              "type": "action",
              "actions": ["activate"],
              "canBeCancelled": true
            },
            "cost": {
              "kind": "all",
              "costs": [
                {"kind": "action", "amount": 1},
                {
                  "kind": "choice",
                  "costs": [
                    {"kind": "resource", "amount": 2},
                    {
                      "kind": "groupResource",
                      "amount": {
                        "kind": "fixedPlusPerPlayer",
                        "fixed": 1,
                        "perPlayer": 2
                      },
                      "scope": {"kind": "sameLocation"}
                    }
                  ]
                },
                {
                  "kind": "clue",
                  "amount": {"kind": "byPlayerCount", "values": [1, 2, 3, 4]}
                },
                {"kind": "clue", "amount": {"kind": "x"}},
                {"kind": "clue", "amount": {"kind": "star"}},
                {"kind": "clue", "amount": {"kind": "unknown"}},
                {"kind": "other"}
              ]
            }
          }]
        }
        """
    }
}
