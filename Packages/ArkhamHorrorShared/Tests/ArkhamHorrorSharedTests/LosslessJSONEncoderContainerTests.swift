@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Coverage for `LosslessJSONValueEncoder`'s container/`superEncoder` mechanics — the parts
/// of `Encoder` conformance that a straightforward JSON-tree walk can easily get wrong even
/// though every "plain" `encode(_:forKey:)`/`encode(_:)` overload round-trips correctly:
/// `superEncoder()`/`superEncoder(forKey:)` must not silently discard what is encoded
/// through them, and nested containers vended from an *unkeyed* container must report the
/// array index they occupy in their own `codingPath`.
@Suite("LosslessJSONValueEncoder container mechanics")
struct LosslessJSONEncoderContainerTests {
    // MARK: - superEncoder does not discard data

    private enum Key: String, CodingKey {
        case fieldA
        case fieldB
    }

    private struct WritesThroughKeyedSuperEncoder: Encodable {
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            try container.encode("a-value", forKey: .fieldA)
            let superEncoder = container.superEncoder(forKey: .fieldB)
            var superContainer = superEncoder.singleValueContainer()
            try superContainer.encode("b-value")
        }
    }

    @Test("superEncoder(forKey:) writes its encoded value back under that key")
    func superEncoderForKeyWritesBack() throws {
        let data = try ContractJSON.encode(WritesThroughKeyedSuperEncoder())
        let value = try ContractJSON.decode(JSONValue.self, from: data)
        #expect(value == .object(["fieldA": .string("a-value"), "fieldB": .string("b-value")]))
    }

    private struct WritesThroughBareSuperEncoder: Encodable {
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            try container.encode("a-value", forKey: .fieldA)
            let superEncoder = container.superEncoder()
            var superContainer = superEncoder.singleValueContainer()
            try superContainer.encode("super-value")
        }
    }

    @Test("A bare superEncoder() writes its encoded value back under the \"super\" key")
    func bareSuperEncoderWritesBackUnderSuperKey() throws {
        let data = try ContractJSON.encode(WritesThroughBareSuperEncoder())
        let value = try ContractJSON.decode(JSONValue.self, from: data)
        #expect(value == .object(["fieldA": .string("a-value"), "super": .string("super-value")]))
    }

    private struct WritesThroughUnkeyedSuperEncoder: Encodable {
        func encode(to encoder: any Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode("first")
            let superEncoder = container.superEncoder()
            try container.encode("third")
            var superContainer = superEncoder.singleValueContainer()
            try superContainer.encode("second")
        }
    }

    @Test("An unkeyed superEncoder() reserves its index so a later write cannot steal the slot")
    func unkeyedSuperEncoderReservesIndexAndWritesBack() throws {
        let data = try ContractJSON.encode(WritesThroughUnkeyedSuperEncoder())
        let value = try ContractJSON.decode(JSONValue.self, from: data)
        let expected: [JSONValue] = [.string("first"), .string("second"), .string("third")]
        #expect(value == .array(expected))
    }

    private struct DiscardsIfNeverEncodedTo: Encodable {
        func encode(to encoder: any Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode("first")
            _ = container.superEncoder() // never actually encoded to
            try container.encode("third")
        }
    }

    @Test("An unkeyed superEncoder() that is never encoded to leaves its reserved slot null")
    func unkeyedSuperEncoderNeverUsedLeavesNullPlaceholder() throws {
        let data = try ContractJSON.encode(DiscardsIfNeverEncodedTo())
        let value = try ContractJSON.decode(JSONValue.self, from: data)
        #expect(value == .array([.string("first"), .null, .string("third")]))
    }

    // MARK: - Nested-container coding paths from an unkeyed container include the index

    private final class CapturedPath: @unchecked Sendable {
        var path: [CodingKey] = []
    }

    private struct PathCapturingValue: Encodable {
        let capture: CapturedPath
        func encode(to encoder: any Encoder) throws {
            capture.path = encoder.codingPath
            var container = encoder.singleValueContainer()
            try container.encode("captured")
        }
    }

    @Test("nestedContainer(keyedBy:) from an unkeyed container includes its array index")
    func nestedKeyedContainerFromUnkeyedIncludesIndex() throws {
        let capture = CapturedPath()
        struct Wrapper: Encodable {
            let capture: CapturedPath
            func encode(to encoder: any Encoder) throws {
                var unkeyed = encoder.unkeyedContainer()
                try unkeyed.encode("padding")
                try unkeyed.encode("padding")
                var nested = unkeyed.nestedContainer(keyedBy: Key.self)
                try nested.encode(PathCapturingValue(capture: capture), forKey: .fieldA)
            }
        }
        _ = try ContractJSON.encode(Wrapper(capture: capture))
        // The captured path is [<array index 2>, .fieldA]; the array-index element must report
        // intValue 2 (the slot the nested object actually occupies), not be omitted.
        #expect(capture.path.count == 2)
        #expect(capture.path.first?.intValue == 2)
        #expect(capture.path.last?.stringValue == "fieldA")
    }

    @Test("nestedUnkeyedContainer() from an unkeyed container includes its array index")
    func nestedUnkeyedContainerFromUnkeyedIncludesIndex() throws {
        let capture = CapturedPath()
        struct Wrapper: Encodable {
            let capture: CapturedPath
            func encode(to encoder: any Encoder) throws {
                var unkeyed = encoder.unkeyedContainer()
                try unkeyed.encode("padding")
                var nested = unkeyed.nestedUnkeyedContainer()
                try nested.encode(PathCapturingValue(capture: capture))
            }
        }
        _ = try ContractJSON.encode(Wrapper(capture: capture))
        // The captured path is [<outer array index 1>, <inner array index 0>]: the outer
        // index (this test's fix) and the inner index (already correct beforehand).
        #expect(capture.path.count == 2)
        #expect(capture.path.first?.intValue == 1)
        #expect(capture.path.last?.intValue == 0)
    }
}
