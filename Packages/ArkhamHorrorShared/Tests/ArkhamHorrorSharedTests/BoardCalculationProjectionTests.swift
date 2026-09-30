@testable import ArkhamHorrorShared
import Testing

@Suite("BoardProjection — calculation summaries")
struct BoardCalculationProjectionTests {
    @Test("Enemy calculation tags render display values")
    func enemyCalculationTagsRender() {
        #expect(calculation("Static", number(2), players: 3)?.displayValue == "2")
        #expect(calculation("PerPlayer", number(2), players: 3)?.displayValue == "6")
        #expect(
            calculation("StaticWithPerPlayer", numbers([1, 2]), players: 3)?.displayValue == "7"
        )
        #expect(
            calculation("ByPlayerCount", numbers([1, 2, 4, 8]), players: 3)?.displayValue == "4"
        )
        #expect(calculation("ValueX", nil, players: 3)?.displayValue == "X")
        #expect(calculation("ValueStar", nil, players: 3)?.displayValue == "–")
    }

    @Test("Enemy per-player calculations clamp instead of trapping on overflow")
    func enemyCalculationOverflowClamps() {
        let huge = Int64.max
        #expect(
            calculation("PerPlayer", number(huge), players: 2)?.staticValue == Int.max
        )
        #expect(
            calculation("StaticWithPerPlayer", numbers([huge, huge]), players: 2)?.staticValue
                == Int.max
        )
        let hugeNegative = (Int64.min / 2) - 1
        #expect(
            calculation("PerPlayer", number(hugeNegative), players: 3)?.staticValue == Int.min
        )
        #expect(
            calculation(
                "StaticWithPerPlayer", numbers([hugeNegative, hugeNegative]), players: 3
            )?.staticValue == Int.min
        )
    }

    private func calculation(
        _ tag: String, _ contents: JSONValue?, players: Int
    ) -> BoardCalculationSummary? {
        BoardProjectionBuilder.calculationSummary(
            in: .object([
                "tag": .string("GameValueCalculation"),
                "contents": .object([
                    "tag": .string(tag),
                    "contents": contents ?? .null,
                ]),
            ]),
            playerCount: players
        )
    }

    private func numbers(_ values: [Int64]) -> JSONValue {
        .array(values.map(number))
    }

    private func number(_ value: Int64) -> JSONValue {
        .number(.integer(value))
    }
}
