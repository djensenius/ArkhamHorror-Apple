import Foundation

struct LosslessJSONUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let codingPath: [CodingKey]
    let box: ArrayBox

    var count: Int {
        box.elements.count
    }

    mutating func encodeNil() throws {
        box.elements.append(.leaf(.null))
    }

    mutating func encode(_ value: Bool) throws {
        box.elements.append(.leaf(.bool(value)))
    }

    mutating func encode(_ value: String) throws {
        box.elements.append(.leaf(.string(value)))
    }

    mutating func encode(_ value: Double) throws {
        try box.elements.append(.leaf(.number(JSONNumber(double: value))))
    }

    mutating func encode(_ value: Float) throws {
        try box.elements.append(.leaf(.number(JSONNumber(double: Double(value)))))
    }

    mutating func encode(_ value: Int) throws {
        box.elements.append(.leaf(.number(.integer(Int64(value)))))
    }

    mutating func encode(_ value: Int8) throws {
        box.elements.append(.leaf(.number(.integer(Int64(value)))))
    }

    mutating func encode(_ value: Int16) throws {
        box.elements.append(.leaf(.number(.integer(Int64(value)))))
    }

    mutating func encode(_ value: Int32) throws {
        box.elements.append(.leaf(.number(.integer(Int64(value)))))
    }

    mutating func encode(_ value: Int64) throws {
        box.elements.append(.leaf(.number(.integer(value))))
    }

    mutating func encode(_ value: UInt) throws {
        box.elements.append(.leaf(.number(.unsignedInteger(UInt64(value)))))
    }

    mutating func encode(_ value: UInt8) throws {
        box.elements.append(.leaf(.number(.unsignedInteger(UInt64(value)))))
    }

    mutating func encode(_ value: UInt16) throws {
        box.elements.append(.leaf(.number(.unsignedInteger(UInt64(value)))))
    }

    mutating func encode(_ value: UInt32) throws {
        box.elements.append(.leaf(.number(.unsignedInteger(UInt64(value)))))
    }

    mutating func encode(_ value: UInt64) throws {
        box.elements.append(.leaf(.number(.unsignedInteger(value))))
    }

    mutating func encode(_ value: some Encodable) throws {
        let elementKey = AnyCodingKey(intValue: count)
        let child = LosslessJSONValueEncoder(codingPath: codingPath + [elementKey])
        try value.encode(to: child)
        box.elements.append(child.node)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy _: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        let index = box.elements.count
        let nestedBox = ObjectBox()
        box.elements.append(.object(nestedBox))
        let container = LosslessJSONKeyedEncodingContainer<NestedKey>(
            codingPath: codingPath + [AnyCodingKey(intValue: index)],
            box: nestedBox
        )
        return KeyedEncodingContainer(container)
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let index = box.elements.count
        let nestedBox = ArrayBox()
        box.elements.append(.array(nestedBox))
        return LosslessJSONUnkeyedEncodingContainer(
            codingPath: codingPath + [AnyCodingKey(intValue: index)],
            box: nestedBox
        )
    }

    mutating func superEncoder() -> Encoder {
        // Reserve the slot immediately (not just at deinit) so any sibling `encode(_:)`
        // calls made after this one still see the correct, stable index.
        let index = box.elements.count
        box.elements.append(.leaf(.null))
        return LosslessJSONReferencingEncoder(
            unkeyedInto: box,
            index: index,
            codingPath: codingPath + [AnyCodingKey(intValue: index)]
        )
    }
}

struct LosslessJSONSingleValueEncodingContainer: SingleValueEncodingContainer {
    let codingPath: [CodingKey]
    let encoder: LosslessJSONValueEncoder

    mutating func encodeNil() throws {
        encoder.node = .leaf(.null)
    }

    mutating func encode(_ value: Bool) throws {
        encoder.node = .leaf(.bool(value))
    }

    mutating func encode(_ value: String) throws {
        encoder.node = .leaf(.string(value))
    }

    mutating func encode(_ value: Double) throws {
        encoder.node = try .leaf(.number(JSONNumber(double: value)))
    }

    mutating func encode(_ value: Float) throws {
        encoder.node = try .leaf(.number(JSONNumber(double: Double(value))))
    }

    mutating func encode(_ value: Int) throws {
        encoder.node = .leaf(.number(.integer(Int64(value))))
    }

    mutating func encode(_ value: Int8) throws {
        encoder.node = .leaf(.number(.integer(Int64(value))))
    }

    mutating func encode(_ value: Int16) throws {
        encoder.node = .leaf(.number(.integer(Int64(value))))
    }

    mutating func encode(_ value: Int32) throws {
        encoder.node = .leaf(.number(.integer(Int64(value))))
    }

    mutating func encode(_ value: Int64) throws {
        encoder.node = .leaf(.number(.integer(value)))
    }

    mutating func encode(_ value: UInt) throws {
        encoder.node = .leaf(.number(.unsignedInteger(UInt64(value))))
    }

    mutating func encode(_ value: UInt8) throws {
        encoder.node = .leaf(.number(.unsignedInteger(UInt64(value))))
    }

    mutating func encode(_ value: UInt16) throws {
        encoder.node = .leaf(.number(.unsignedInteger(UInt64(value))))
    }

    mutating func encode(_ value: UInt32) throws {
        encoder.node = .leaf(.number(.unsignedInteger(UInt64(value))))
    }

    mutating func encode(_ value: UInt64) throws {
        encoder.node = .leaf(.number(.unsignedInteger(value)))
    }

    mutating func encode(_ value: some Encodable) throws {
        try value.encode(to: encoder)
    }
}

// Renders a ``JSONValue`` tree to bytes without Foundation's `JSONEncoder`/
// `JSONSerialization`. Numbers render via ``JSONNumber/description`` (the original
// ``JSONNumber/rawToken``, when present, byte-for-byte), and object keys are sorted for
// deterministic output (``JSONValue/object(_:)``'s `[String: JSONValue]` storage does not
// itself preserve source key order).
