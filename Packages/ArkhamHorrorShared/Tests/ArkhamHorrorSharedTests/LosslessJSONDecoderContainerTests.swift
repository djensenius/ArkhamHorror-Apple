@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Alias purely to keep the `UnkeyedScalarKind.decode(from:)` family's signatures under
/// the line length limit. File-scope (not nested) to respect SwiftLint's one-level
/// type-nesting limit, since `UnkeyedScalarKind` itself is already nested one level. Not
/// `private`: methods using it as a parameter type need at least the enclosing enum's
/// (internal) visibility for the Swift Testing macro's discovery.
typealias UnkeyedContainer = LosslessJSONUnkeyedDecodingContainer

/// Coverage for `LosslessJSONValueDecoder`/its containers' error-reporting fidelity: a
/// genuine type mismatch under the lossless decode path must surface as an actual
/// `DecodingError.typeMismatch` naming the real offending value's *kind* (never a
/// hardcoded `.null` placeholder) and the exact coding path (including array indices/keys)
/// — never a misleading "decode through ContractJSON instead" message (which is only ever
/// appropriate for a *stock* `Decoder`). Descriptions deliberately name only the mismatched
/// node's kind, not its full (possibly huge, recursive) content/subtree — see
/// `JSONValue.kindDescription`.
@Suite("LosslessJSONValueDecoder container error fidelity")
struct LosslessJSONDecoderContainerTests {
    // MARK: - JSONNumber decode through ContractJSON on a non-numeric value

    @Test(
        "A non-numeric value decoded as JSONNumber is a real typeMismatch, not a message",
        arguments: [
            "true", "false", "null", "\"not-a-number\"", "[]", "{}",
        ]
    )
    func nonNumericValueIsTypeMismatchNotStockDecoderMessage(literal: String) throws {
        #expect {
            _ = try ContractJSON.decode(JSONNumber.self, from: Data(literal.utf8))
        } throws: { error in
            guard let decodingError = error as? DecodingError else { return false }
            guard case let .typeMismatch(type, context) = decodingError else { return false }
            // Must name the type actually expected, and must never mention the
            // stock-`Decoder` "Decode through ContractJSON instead" fallback message —
            // that message is only correct when there genuinely was no lossless numeral
            // to expose, not when this decoder had a non-numeric value all along.
            return type == JSONNumber.self
                && !context.debugDescription.contains("Decode through ContractJSON")
        }
    }

    private struct ExternalIDLikeWrapper: Decodable {
        let number: JSONNumber
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            number = try container.decode(JSONNumber.self)
        }
    }

    @Test("A boolean where a numeric external ID is expected is a real typeMismatch")
    func booleanInPlaceOfNumericIDIsTypeMismatch() throws {
        #expect {
            _ = try ContractJSON.decode(ExternalIDLikeWrapper.self, from: Data("true".utf8))
        } throws: { error in
            guard let decodingError = error as? DecodingError else { return false }
            guard case .typeMismatch = decodingError else { return false }
            return true
        }
    }

    // MARK: - Unkeyed container: nestedContainer(keyedBy:) reports the real value/index

    @Test("Unkeyed nestedContainer(keyedBy:) on a non-object reports the real value")
    func unkeyedNestedKeyedContainerReportsRealValueOnMismatch() throws {
        // Element at index 1 is a string, not an object.
        let json = "[1, \"not-an-object\", 3]"
        struct Wrapper: Decodable {
            init(from decoder: any Decoder) throws {
                var unkeyed = try decoder.unkeyedContainer()
                _ = try unkeyed.decode(Int.self)
                _ = try unkeyed.nestedContainer(keyedBy: AnyCodingKeyForTest.self)
            }
        }
        #expect {
            _ = try ContractJSON.decode(Wrapper.self, from: Data(json.utf8))
        } throws: { error in
            guard let decodingError = error as? DecodingError else { return false }
            guard case let .typeMismatch(_, context) = decodingError else { return false }
            // The real mismatched value's *kind* ("string") must appear in the
            // description — never a hardcoded "null" placeholder that misreports what was
            // actually there. (The description deliberately never includes the value's own
            // content/subtree, so a genuine type mismatch and a `.null` placeholder bug are
            // distinguished by kind name, not literal text — see `JSONValue.kindDescription`.)
            let mentionsRealKind = context.debugDescription.contains("string")
            let mentionsNull = context.debugDescription.contains("null")
            // The failing array index (1) must be present in the reported coding path.
            let pathHasIndex = context.codingPath.contains { $0.intValue == 1 }
            return mentionsRealKind && !mentionsNull && pathHasIndex
        }
    }

    @Test("Unkeyed nestedUnkeyedContainer() on a non-array reports the real value")
    func unkeyedNestedUnkeyedContainerReportsRealValueOnMismatch() throws {
        // Element at index 2 is a number, not an array.
        let json = "[\"a\", \"b\", 42]"
        struct Wrapper: Decodable {
            init(from decoder: any Decoder) throws {
                var unkeyed = try decoder.unkeyedContainer()
                _ = try unkeyed.decode(String.self)
                _ = try unkeyed.decode(String.self)
                _ = try unkeyed.nestedUnkeyedContainer()
            }
        }
        #expect {
            _ = try ContractJSON.decode(Wrapper.self, from: Data(json.utf8))
        } throws: { error in
            guard let decodingError = error as? DecodingError else { return false }
            guard case let .typeMismatch(_, context) = decodingError else { return false }
            let mentionsRealKind = context.debugDescription.contains("number")
            let mentionsNull = context.debugDescription.contains("null")
            let pathHasIndex = context.codingPath.contains { $0.intValue == 2 }
            return mentionsRealKind && !mentionsNull && pathHasIndex
        }
    }

    // MARK: - Keyed container: nested containers report the field's key in coding path

    private enum FieldKey: String, CodingKey {
        case nested
    }

    @Test("Keyed nestedContainer(keyedBy:forKey:) on a non-object includes the key")
    func keyedNestedKeyedContainerIncludesKeyOnMismatch() throws {
        let json = #"{"nested": "not-an-object"}"#
        struct Wrapper: Decodable {
            init(from decoder: any Decoder) throws {
                let keyed = try decoder.container(keyedBy: FieldKey.self)
                _ = try keyed.nestedContainer(keyedBy: AnyCodingKeyForTest.self, forKey: .nested)
            }
        }
        #expect {
            _ = try ContractJSON.decode(Wrapper.self, from: Data(json.utf8))
        } throws: { error in
            guard let decodingError = error as? DecodingError else { return false }
            guard case let .typeMismatch(_, context) = decodingError else { return false }
            let mentionsRealKind = context.debugDescription.contains("string")
            let pathHasKey = context.codingPath.contains { $0.stringValue == "nested" }
            return mentionsRealKind && pathHasKey
        }
    }

    @Test("Keyed nestedUnkeyedContainer(forKey:) on a non-array includes the key")
    func keyedNestedUnkeyedContainerIncludesKeyOnMismatch() throws {
        let json = #"{"nested": "not-an-array"}"#
        struct Wrapper: Decodable {
            init(from decoder: any Decoder) throws {
                let keyed = try decoder.container(keyedBy: FieldKey.self)
                _ = try keyed.nestedUnkeyedContainer(forKey: .nested)
            }
        }
        #expect {
            _ = try ContractJSON.decode(Wrapper.self, from: Data(json.utf8))
        } throws: { error in
            guard let decodingError = error as? DecodingError else { return false }
            guard case let .typeMismatch(_, context) = decodingError else { return false }
            let mentionsRealKind = context.debugDescription.contains("string")
            let pathHasKey = context.codingPath.contains { $0.stringValue == "nested" }
            return mentionsRealKind && pathHasKey
        }
    }

    // MARK: - Unkeyed container: every scalar decode(_:) overload reports the real index

    /// Every scalar overload `LosslessJSONUnkeyedDecodingContainer.decode(_:)` supports,
    /// so a single parameterized test can drive all of them through the same mismatch.
    /// Not `private`: a `@Test` method's parameter type must be no more restrictive than
    /// the method itself, and `@Test` methods need at least internal visibility for the
    /// Swift Testing macro's discovery to see them from the module's test entry point.
    enum UnkeyedScalarKind: String, CaseIterable, CustomStringConvertible {
        case bool, string, double, float
        case int, int8, int16, int32, int64
        case uint, uint8, uint16, uint32, uint64

        var description: String {
            rawValue
        }

        /// Split into three sub-switches (each well under SwiftLint's cyclomatic-complexity
        /// limit) rather than one 14-case switch.
        func decode(from container: inout UnkeyedContainer) throws {
            switch self {
            case .bool, .string, .double, .float:
                try decodeNonInteger(from: &container)
            case .int, .int8, .int16, .int32, .int64:
                try decodeSignedInteger(from: &container)
            case .uint, .uint8, .uint16, .uint32, .uint64:
                try decodeUnsignedInteger(from: &container)
            }
        }

        private func decodeNonInteger(from container: inout UnkeyedContainer) throws {
            switch self {
            case .bool: _ = try container.decode(Bool.self)
            case .string: _ = try container.decode(String.self)
            case .double: _ = try container.decode(Double.self)
            case .float: _ = try container.decode(Float.self)
            default: break
            }
        }

        private func decodeSignedInteger(from container: inout UnkeyedContainer) throws {
            switch self {
            case .int: _ = try container.decode(Int.self)
            case .int8: _ = try container.decode(Int8.self)
            case .int16: _ = try container.decode(Int16.self)
            case .int32: _ = try container.decode(Int32.self)
            case .int64: _ = try container.decode(Int64.self)
            default: break
            }
        }

        private func decodeUnsignedInteger(from container: inout UnkeyedContainer) throws {
            switch self {
            case .uint: _ = try container.decode(UInt.self)
            case .uint8: _ = try container.decode(UInt8.self)
            case .uint16: _ = try container.decode(UInt16.self)
            case .uint32: _ = try container.decode(UInt32.self)
            case .uint64: _ = try container.decode(UInt64.self)
            default: break
            }
        }
    }

    @Test(
        "Every unkeyed scalar decode(_:) overload reports the real failing index",
        arguments: UnkeyedScalarKind.allCases
    )
    func unkeyedScalarDecodeIncludesFailingIndex(kind: UnkeyedScalarKind) throws {
        // An object never satisfies any scalar overload, so element 2 always mismatches
        // regardless of which scalar type is requested.
        let wire = try ContractJSON.decode(JSONValue.self, from: Data("[1, 2, {}]".utf8))
        guard case let .array(items) = wire else {
            Issue.record("Expected a parsed JSON array")
            return
        }
        var container = LosslessJSONUnkeyedDecodingContainer(elements: items, codingPath: [])
        _ = try container.decode(Int.self)
        _ = try container.decode(Int.self)
        #expect {
            try kind.decode(from: &container)
        } throws: { error in
            guard let decodingError = error as? DecodingError else { return false }
            guard case let .typeMismatch(_, context) = decodingError else { return false }
            return context.codingPath.contains { $0.intValue == 2 }
        }
    }

    // MARK: - Unkeyed container: at-end errors (decodeNil/scalar reads past the end)

    @Test("decodeNil() past the end of an unkeyed container reports the failing index")
    func decodeNilPastEndReportsIndex() throws {
        let wire = try ContractJSON.decode(JSONValue.self, from: Data("[1]".utf8))
        guard case let .array(items) = wire else {
            Issue.record("Expected a parsed JSON array")
            return
        }
        var container = LosslessJSONUnkeyedDecodingContainer(elements: items, codingPath: [])
        _ = try container.decode(Int.self)
        #expect {
            _ = try container.decodeNil()
        } throws: { error in
            guard let decodingError = error as? DecodingError else { return false }
            guard case let .valueNotFound(_, context) = decodingError else { return false }
            // Element 1 is the position that was requested but does not exist.
            return context.codingPath.contains { $0.intValue == 1 }
        }
    }

    @Test("A scalar decode(_:) past the end of an unkeyed container reports the failing index")
    func scalarDecodePastEndReportsIndex() throws {
        let wire = try ContractJSON.decode(JSONValue.self, from: Data("[]".utf8))
        guard case let .array(items) = wire else {
            Issue.record("Expected a parsed JSON array")
            return
        }
        var container = LosslessJSONUnkeyedDecodingContainer(elements: items, codingPath: [])
        #expect {
            _ = try container.decode(Int.self)
        } throws: { error in
            guard let decodingError = error as? DecodingError else { return false }
            guard case let .valueNotFound(_, context) = decodingError else { return false }
            // The empty container's first (nonexistent) slot is index 0.
            return context.codingPath.contains { $0.intValue == 0 }
        }
    }
}

/// A minimal `CodingKey` used only where a test needs to name a nested-container key type
/// but never actually looks any key up.
private struct AnyCodingKeyForTest: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = "Index \(intValue)"
        self.intValue = intValue
    }
}
