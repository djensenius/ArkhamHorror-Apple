@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Adversarial coverage for `superDecoder()`/`superDecoder(forKey:)` (review round 3,
/// MEDIUM #6): a conventional bare keyed `superDecoder()` must decode the value stored
/// under `"super"` (matching what `superEncoder()` actually writes), not the entire
/// enclosing object; `superDecoder(forKey:)` and the unkeyed container's `superDecoder()`
/// must be equally correct. A multi-level `Codable` class hierarchy — the textbook use
/// case for `superEncoder`/`superDecoder` — is the most direct proof these interoperate
/// correctly across encode and decode.
@Suite("Lossless JSON superDecoder")
struct LosslessJSONSuperDecoderTests {
    private enum AnimalKeys: String, CodingKey {
        case name
    }

    private enum DogKeys: String, CodingKey {
        case breed
    }

    private enum PuppyKeys: String, CodingKey {
        case ageMonths
        case dogSuper
    }

    /// Base of a 3-level inheritance chain. Encodes/decodes through a plain keyed
    /// container — no `superEncoder` involved at this level, since it has no superclass of
    /// its own.
    private class Animal: Codable {
        let name: String
        init(name: String) {
            self.name = name
        }

        required init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnimalKeys.self)
            name = try container.decode(String.self, forKey: .name)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: AnimalKeys.self)
            try container.encode(name, forKey: .name)
        }
    }

    /// Middle of the chain: writes its own field alongside the superclass's data via a
    /// *bare* `superEncoder()`/`superDecoder()` — the conventional "super" key.
    private class Dog: Animal {
        let breed: String
        init(name: String, breed: String) {
            self.breed = breed
            super.init(name: name)
        }

        required init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: DogKeys.self)
            breed = try container.decode(String.self, forKey: .breed)
            let superDecoder = try container.superDecoder()
            try super.init(from: superDecoder)
        }

        override func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: DogKeys.self)
            try container.encode(breed, forKey: .breed)
            let superEncoder = container.superEncoder()
            try super.encode(to: superEncoder)
        }
    }

    /// Top of the chain: uses `superEncoder(forKey:)`/`superDecoder(forKey:)` with an
    /// explicit custom key instead of the bare "super" convention, exercising that overload
    /// too.
    private class Puppy: Dog {
        let ageMonths: Int
        init(name: String, breed: String, ageMonths: Int) {
            self.ageMonths = ageMonths
            super.init(name: name, breed: breed)
        }

        required init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: PuppyKeys.self)
            ageMonths = try container.decode(Int.self, forKey: .ageMonths)
            let superDecoder = try container.superDecoder(forKey: .dogSuper)
            try super.init(from: superDecoder)
        }

        override func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: PuppyKeys.self)
            try container.encode(ageMonths, forKey: .ageMonths)
            let superEncoder = container.superEncoder(forKey: .dogSuper)
            try super.encode(to: superEncoder)
        }
    }

    @Test("A base/child/grandchild class hierarchy round-trips through superEncoder/superDecoder")
    func threeLevelHierarchyRoundTrips() throws {
        let original = Puppy(name: "Rex", breed: "Labrador", ageMonths: 4)
        let data = try ContractJSON.encode(original)

        // The wire shape itself: nested "super" objects at every level, exactly matching
        // what `superEncoder`/`superEncoder(forKey:)` actually write.
        let wire = try ContractJSON.decode(JSONValue.self, from: data)
        #expect(
            wire == .object([
                "ageMonths": .number(.integer(4)),
                "dogSuper": .object([
                    "breed": .string("Labrador"),
                    "super": .object(["name": .string("Rex")]),
                ]),
            ])
        )

        let decoded = try ContractJSON.decode(Puppy.self, from: data)
        #expect(decoded.name == "Rex")
        #expect(decoded.breed == "Labrador")
        #expect(decoded.ageMonths == 4)
    }

    // MARK: - Missing/malformed super

    private enum FlatKeys: String, CodingKey {
        case fieldA
        case fieldB
    }

    @Test("superDecoder(forKey:) does not throw merely because the key is absent")
    func superDecoderForAbsentKeyDoesNotThrowByItself() throws {
        struct HasOptionalSuper: Decodable {
            let fieldAValue: String
            let superWasNull: Bool
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: FlatKeys.self)
                fieldAValue = try container.decode(String.self, forKey: .fieldA)
                // "fieldB" (the super slot) is entirely absent from the wire bytes below;
                // per the doc comment on `makeSuperDecoder`, this must not throw by itself.
                let superDecoder = try container.superDecoder(forKey: .fieldB)
                let singleValue = try superDecoder.singleValueContainer()
                superWasNull = singleValue.decodeNil()
            }
        }
        let bytes = Data(#"{"fieldA":"hello"}"#.utf8)
        let decoded = try ContractJSON.decode(HasOptionalSuper.self, from: bytes)
        #expect(decoded.fieldAValue == "hello")
        #expect(decoded.superWasNull)
    }

    @Test("A bare superDecoder() for an absent \"super\" key also does not throw by itself")
    func bareSuperDecoderForAbsentKeyDoesNotThrowByItself() throws {
        struct HasOptionalBareSuper: Decodable {
            let superWasNull: Bool
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: FlatKeys.self)
                let superDecoder = try container.superDecoder()
                let singleValue = try superDecoder.singleValueContainer()
                superWasNull = singleValue.decodeNil()
            }
        }
        // No "super" key at all in the wire bytes.
        let bytes = Data(#"{"fieldA":"hello"}"#.utf8)
        let decoded = try ContractJSON.decode(HasOptionalBareSuper.self, from: bytes)
        #expect(decoded.superWasNull)
    }

    @Test("A missing super key only fails once the superclass requires a keyed container")
    func missingSuperKeyFailsOnlyWhenSuperclassRequiresContainer() {
        struct RequiresKeyedSuper: Decodable {
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: FlatKeys.self)
                let superDecoder = try container.superDecoder(forKey: .fieldB)
                // The "super" slot decodes to `.null` (never encoded); asking it for a
                // keyed container is the malformed case, and must throw.
                _ = try superDecoder.container(keyedBy: FlatKeys.self)
            }
        }
        let bytes = Data(#"{"fieldA":"hello"}"#.utf8)
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(RequiresKeyedSuper.self, from: bytes)
        }
    }

    @Test("A super key present but holding the wrong shape fails with a type mismatch")
    func malformedSuperValueFailsWithTypeMismatch() {
        struct RequiresKeyedSuper: Decodable {
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: FlatKeys.self)
                let superDecoder = try container.superDecoder(forKey: .fieldB)
                _ = try superDecoder.container(keyedBy: FlatKeys.self)
            }
        }
        // "fieldB" (the super slot) is present, but holds a string, not an object.
        let bytes = Data(#"{"fieldA":"hello","fieldB":"not-an-object"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try ContractJSON.decode(RequiresKeyedSuper.self, from: bytes)
        }
    }

    // MARK: - Coding paths

    @Test("A bare superDecoder()'s codingPath ends with the \"super\" key")
    func bareSuperDecoderCodingPath() throws {
        let decoder = try LosslessJSONValueDecoder(
            value: LosslessJSONParser.parse(Data(#"{"fieldA":"x"}"#.utf8)),
            codingPath: []
        )
        let container = try decoder.container(keyedBy: FlatKeys.self)
        let superDecoder = try container.superDecoder()
        #expect(superDecoder.codingPath.count == 1)
        #expect(superDecoder.codingPath.last?.stringValue == "super")
    }

    @Test("A keyed superDecoder(forKey:)'s codingPath ends with that exact key")
    func keyedSuperDecoderCodingPath() throws {
        let decoder = try LosslessJSONValueDecoder(
            value: LosslessJSONParser.parse(Data(#"{"fieldA":"x"}"#.utf8)),
            codingPath: []
        )
        let container = try decoder.container(keyedBy: FlatKeys.self)
        let superDecoder = try container.superDecoder(forKey: .fieldB)
        #expect(superDecoder.codingPath.count == 1)
        #expect(superDecoder.codingPath.last?.stringValue == "fieldB")
    }

    @Test("An unkeyed container's superDecoder() codingPath ends with its array index")
    func unkeyedSuperDecoderCodingPath() throws {
        let decoder = try LosslessJSONValueDecoder(
            value: LosslessJSONParser.parse(Data(#"["first","second","third"]"#.utf8)),
            codingPath: []
        )
        var unkeyed = try decoder.unkeyedContainer()
        _ = try unkeyed.decode(String.self)
        let superDecoder = try unkeyed.superDecoder()
        #expect(superDecoder.codingPath.count == 1)
        #expect(superDecoder.codingPath.last?.intValue == 1)
        let value = try String(from: superDecoder)
        #expect(value == "second")
    }

    // MARK: - Errors thrown while encoding through a superEncoder are not silently lost

    private enum SuperEncoderKeys: String, CodingKey {
        case fieldA
        case fieldB
    }

    private struct SentinelEncodingError: Error, Equatable {}

    private struct ThrowsPartwayThroughEncoding: Encodable {
        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            // Encode *something* first, so `node` inside the referencing encoder is
            // non-trivial by the time the throw unwinds it — proving the deinit write-back
            // of that partial state can never substitute for, or swallow, the error.
            try container.encode("partial-value")
            throw SentinelEncodingError()
        }
    }

    private struct WritesThroughSuperEncoderThatThrows: Encodable {
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: SuperEncoderKeys.self)
            try container.encode("a-value", forKey: .fieldA)
            let superEncoder = container.superEncoder(forKey: .fieldB)
            try ThrowsPartwayThroughEncoding().encode(to: superEncoder)
        }
    }

    @Test("An error thrown while encoding through a superEncoder propagates to the top level")
    func errorThroughSuperEncoderPropagatesToTopLevel() {
        #expect(throws: SentinelEncodingError.self) {
            _ = try ContractJSON.encode(WritesThroughSuperEncoderThatThrows())
        }
    }
}
