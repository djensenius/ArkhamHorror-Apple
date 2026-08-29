@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Coverage for `LosslessJSONValueDecoder`/its containers' error-reporting fidelity: a
/// genuine type mismatch under the lossless decode path must surface as an actual
/// `DecodingError.typeMismatch` naming the real offending value and the exact coding path
/// (including array indices/keys) — never a misleading "decode through ContractJSON
/// instead" message (which is only ever appropriate for a *stock* `Decoder`), and never a
/// hardcoded `.null` placeholder or a path missing the failing element's position.
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
            // The real mismatched value ("not-an-object") must appear in the description,
            // never a hardcoded "null" placeholder that misreports what was actually there.
            let mentionsRealValue = context.debugDescription.contains("not-an-object")
            let mentionsNull = context.debugDescription.contains("JSONValue.null")
            // The failing array index (1) must be present in the reported coding path.
            let pathHasIndex = context.codingPath.contains { $0.intValue == 1 }
            return mentionsRealValue && !mentionsNull && pathHasIndex
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
            let mentionsRealValue = context.debugDescription.contains("42")
            let mentionsNull = context.debugDescription.contains("JSONValue.null")
            let pathHasIndex = context.codingPath.contains { $0.intValue == 2 }
            return mentionsRealValue && !mentionsNull && pathHasIndex
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
            let mentionsRealValue = context.debugDescription.contains("not-an-object")
            let pathHasKey = context.codingPath.contains { $0.stringValue == "nested" }
            return mentionsRealValue && pathHasKey
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
            let mentionsRealValue = context.debugDescription.contains("not-an-array")
            let pathHasKey = context.codingPath.contains { $0.stringValue == "nested" }
            return mentionsRealValue && pathHasKey
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
