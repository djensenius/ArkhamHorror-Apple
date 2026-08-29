import Foundation

// MARK: - Encoding

/// An `Encodable`-graph node under construction. `.object`/`.array` hold live references
/// (`ObjectBox`/`ArrayBox`) rather than a `JSONValue` copy, because `nestedContainer(...)`
/// vends a container that is filled in by *subsequent* statements in the caller's
/// `encode(to:)` — a plain value-type `JSONValue` snapshotted at vend time would miss all
/// of those later mutations.
enum EncodingNode {
    case leaf(JSONValue)
    case object(ObjectBox)
    case array(ArrayBox)

    var jsonValue: JSONValue {
        switch self {
        case let .leaf(value): value
        case let .object(box): box.jsonValue
        case let .array(box): box.jsonValue
        }
    }
}

final class ObjectBox {
    var entries: [String: EncodingNode] = [:]
    var jsonValue: JSONValue {
        .object(entries.mapValues(\.jsonValue))
    }
}

final class ArrayBox {
    var elements: [EncodingNode] = []
    var jsonValue: JSONValue {
        .array(elements.map(\.jsonValue))
    }
}

/// Encodes an `Encodable` type into a ``JSONValue`` tree directly, never through
/// Foundation's `JSONEncoder`, used by ``ContractJSON/encode(_:)``. Conforms to
/// ``LosslessJSONNumberSink``, so a ``JSONNumber`` encoded anywhere in the graph keeps its
/// exact original precision rather than round-tripping through a fixed-precision type.
///
/// Not `final`: ``LosslessJSONReferencingEncoder`` subclasses it to implement
/// `superEncoder()`/`superEncoder(forKey:)`, which must write their encoded value back into
/// the parent container rather than discarding it.
class LosslessJSONValueEncoder: Encoder, LosslessJSONNumberSink {
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]
    var node: EncodingNode = .leaf(.null)

    init(codingPath: [CodingKey] = []) {
        self.codingPath = codingPath
    }

    var encodedValue: JSONValue {
        node.jsonValue
    }

    func encodeLosslessJSONNumber(_ value: JSONNumber) throws {
        node = .leaf(.number(value))
    }

    func container<Key: CodingKey>(keyedBy _: Key.Type) -> KeyedEncodingContainer<Key> {
        let box = ObjectBox()
        node = .object(box)
        let container = LosslessJSONKeyedEncodingContainer<Key>(codingPath: codingPath, box: box)
        return KeyedEncodingContainer(container)
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        let box = ArrayBox()
        node = .array(box)
        return LosslessJSONUnkeyedEncodingContainer(codingPath: codingPath, box: box)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        LosslessJSONSingleValueEncodingContainer(codingPath: codingPath, encoder: self)
    }
}

struct LosslessJSONKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let codingPath: [CodingKey]
    let box: ObjectBox

    private func set(_ node: EncodingNode, forKey key: Key) {
        box.entries[key.stringValue] = node
    }

    mutating func encodeNil(forKey key: Key) throws {
        set(.leaf(.null), forKey: key)
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws {
        set(.leaf(.bool(value)), forKey: key)
    }

    mutating func encode(_ value: String, forKey key: Key) throws {
        set(.leaf(.string(value)), forKey: key)
    }

    mutating func encode(_ value: Double, forKey key: Key) throws {
        try set(.leaf(.number(JSONNumber(double: value))), forKey: key)
    }

    mutating func encode(_ value: Float, forKey key: Key) throws {
        try set(.leaf(.number(JSONNumber(double: Double(value)))), forKey: key)
    }

    mutating func encode(_ value: Int, forKey key: Key) throws {
        set(.leaf(.number(.integer(Int64(value)))), forKey: key)
    }

    mutating func encode(_ value: Int8, forKey key: Key) throws {
        set(.leaf(.number(.integer(Int64(value)))), forKey: key)
    }

    mutating func encode(_ value: Int16, forKey key: Key) throws {
        set(.leaf(.number(.integer(Int64(value)))), forKey: key)
    }

    mutating func encode(_ value: Int32, forKey key: Key) throws {
        set(.leaf(.number(.integer(Int64(value)))), forKey: key)
    }

    mutating func encode(_ value: Int64, forKey key: Key) throws {
        set(.leaf(.number(.integer(value))), forKey: key)
    }

    mutating func encode(_ value: UInt, forKey key: Key) throws {
        set(.leaf(.number(.unsignedInteger(UInt64(value)))), forKey: key)
    }

    mutating func encode(_ value: UInt8, forKey key: Key) throws {
        set(.leaf(.number(.unsignedInteger(UInt64(value)))), forKey: key)
    }

    mutating func encode(_ value: UInt16, forKey key: Key) throws {
        set(.leaf(.number(.unsignedInteger(UInt64(value)))), forKey: key)
    }

    mutating func encode(_ value: UInt32, forKey key: Key) throws {
        set(.leaf(.number(.unsignedInteger(UInt64(value)))), forKey: key)
    }

    mutating func encode(_ value: UInt64, forKey key: Key) throws {
        set(.leaf(.number(.unsignedInteger(value))), forKey: key)
    }

    mutating func encode(_ value: some Encodable, forKey key: Key) throws {
        let child = LosslessJSONValueEncoder(codingPath: codingPath + [key])
        try value.encode(to: child)
        set(child.node, forKey: key)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy _: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let nestedBox = ObjectBox()
        set(.object(nestedBox), forKey: key)
        let container = LosslessJSONKeyedEncodingContainer<NestedKey>(
            codingPath: codingPath + [key],
            box: nestedBox
        )
        return KeyedEncodingContainer(container)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let nestedBox = ArrayBox()
        set(.array(nestedBox), forKey: key)
        return LosslessJSONUnkeyedEncodingContainer(codingPath: codingPath + [key], box: nestedBox)
    }

    mutating func superEncoder() -> Encoder {
        makeSuperEncoder(forKey: "super")
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        makeSuperEncoder(forKey: key.stringValue)
    }

    private func makeSuperEncoder(forKey key: String) -> Encoder {
        LosslessJSONReferencingEncoder(
            keyedInto: box,
            key: key,
            codingPath: codingPath + [AnyCodingKey(stringValue: key)]
        )
    }
}
