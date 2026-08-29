import Foundation

final class LosslessJSONValueDecoder: Decoder, LosslessJSONNumberSource {
    let value: JSONValue
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]

    init(value: JSONValue, codingPath: [CodingKey]) {
        self.value = value
        self.codingPath = codingPath
    }

    func losslessJSONNumber() throws -> JSONNumber? {
        guard case let .number(number) = value else { return nil }
        return number
    }

    func container<Key: CodingKey>(keyedBy _: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case let .object(dictionary) = value else {
            throw LosslessJSONPrimitive.typeMismatch([String: JSONValue].self, value, codingPath)
        }
        return KeyedDecodingContainer(
            LosslessJSONKeyedDecodingContainer<Key>(dictionary: dictionary, codingPath: codingPath)
        )
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard case let .array(elements) = value else {
            throw LosslessJSONPrimitive.typeMismatch([JSONValue].self, value, codingPath)
        }
        return LosslessJSONUnkeyedDecodingContainer(elements: elements, codingPath: codingPath)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        LosslessJSONSingleValueDecodingContainer(value: value, codingPath: codingPath)
    }
}

struct LosslessJSONKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let dictionary: [String: JSONValue]
    let codingPath: [CodingKey]

    var allKeys: [Key] {
        dictionary.keys.compactMap(Key.init(stringValue:))
    }

    func contains(_ key: Key) -> Bool {
        dictionary[key.stringValue] != nil
    }

    private func value(forKey key: Key) throws -> JSONValue {
        guard let value = dictionary[key.stringValue] else {
            let context = DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "No value for key \(key.stringValue)"
            )
            throw DecodingError.keyNotFound(key, context)
        }
        return value
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        if case .null = try value(forKey: key) {
            return true
        }
        return false
    }

    func decode<T: Decodable>(_: T.Type, forKey key: Key) throws -> T {
        let child = try LosslessJSONValueDecoder(
            value: value(forKey: key),
            codingPath: codingPath + [key]
        )
        return try T(from: child)
    }

    func decode(_: Bool.Type, forKey key: Key) throws -> Bool {
        try LosslessJSONPrimitive.bool(value(forKey: key), codingPath: codingPath + [key])
    }

    func decode(_: String.Type, forKey key: Key) throws -> String {
        try LosslessJSONPrimitive.string(value(forKey: key), codingPath: codingPath + [key])
    }

    func decode(_: Double.Type, forKey key: Key) throws -> Double {
        try LosslessJSONPrimitive.double(value(forKey: key), codingPath: codingPath + [key])
    }

    func decode(_: Float.Type, forKey key: Key) throws -> Float {
        try LosslessJSONPrimitive.float(value(forKey: key), codingPath: codingPath + [key])
    }

    func decode(_: Int.Type, forKey key: Key) throws -> Int {
        try LosslessJSONPrimitive.integer(value(forKey: key), codingPath: codingPath + [key])
    }

    func decode(_: Int8.Type, forKey key: Key) throws -> Int8 {
        try LosslessJSONPrimitive.integer(value(forKey: key), codingPath: codingPath + [key])
    }

    func decode(_: Int16.Type, forKey key: Key) throws -> Int16 {
        try LosslessJSONPrimitive.integer(value(forKey: key), codingPath: codingPath + [key])
    }

    func decode(_: Int32.Type, forKey key: Key) throws -> Int32 {
        try LosslessJSONPrimitive.integer(value(forKey: key), codingPath: codingPath + [key])
    }

    func decode(_: Int64.Type, forKey key: Key) throws -> Int64 {
        try LosslessJSONPrimitive.integer(value(forKey: key), codingPath: codingPath + [key])
    }

    func decode(_: UInt.Type, forKey key: Key) throws -> UInt {
        try LosslessJSONPrimitive.integer(value(forKey: key), codingPath: codingPath + [key])
    }

    func decode(_: UInt8.Type, forKey key: Key) throws -> UInt8 {
        try LosslessJSONPrimitive.integer(value(forKey: key), codingPath: codingPath + [key])
    }

    func decode(_: UInt16.Type, forKey key: Key) throws -> UInt16 {
        try LosslessJSONPrimitive.integer(value(forKey: key), codingPath: codingPath + [key])
    }

    func decode(_: UInt32.Type, forKey key: Key) throws -> UInt32 {
        try LosslessJSONPrimitive.integer(value(forKey: key), codingPath: codingPath + [key])
    }

    func decode(_: UInt64.Type, forKey key: Key) throws -> UInt64 {
        try LosslessJSONPrimitive.integer(value(forKey: key), codingPath: codingPath + [key])
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy _: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let nestedValue = try value(forKey: key)
        guard case let .object(dict) = nestedValue else {
            throw LosslessJSONPrimitive.typeMismatch(
                [String: JSONValue].self, nestedValue, codingPath
            )
        }
        let container = LosslessJSONKeyedDecodingContainer<NestedKey>(
            dictionary: dict,
            codingPath: codingPath + [key]
        )
        return KeyedDecodingContainer(container)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        let nestedValue = try value(forKey: key)
        guard case let .array(elements) = nestedValue else {
            throw LosslessJSONPrimitive.typeMismatch([JSONValue].self, nestedValue, codingPath)
        }
        return LosslessJSONUnkeyedDecodingContainer(
            elements: elements,
            codingPath: codingPath + [key]
        )
    }

    func superDecoder() throws -> Decoder {
        makeSuperDecoder(forKey: "super", codingPathKey: AnyCodingKey(stringValue: "super"))
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        makeSuperDecoder(forKey: key.stringValue, codingPathKey: key)
    }

    /// Reads the value stored under `key` (matching what
    /// `LosslessJSONKeyedEncodingContainer.superEncoder()`/`superEncoder(forKey:)` actually
    /// writes — the value *at that key*, never the entire enclosing object), defaulting to
    /// `.null` when the key is absent rather than throwing. Foundation's own `JSONDecoder`
    /// treats a missing "super" key identically: `superDecoder()`/`superDecoder(forKey:)`
    /// are meant to support an optional intermediate class in an inheritance chain that may
    /// not have encoded anything of its own, so a missing key is not malformed input.
    private func makeSuperDecoder(forKey key: String, codingPathKey: CodingKey) -> Decoder {
        LosslessJSONValueDecoder(
            value: dictionary[key] ?? .null,
            codingPath: codingPath + [codingPathKey]
        )
    }
}

struct LosslessJSONUnkeyedDecodingContainer: UnkeyedDecodingContainer {
    let elements: [JSONValue]
    let codingPath: [CodingKey]
    private(set) var currentIndex: Int = 0

    var count: Int? {
        elements.count
    }

    var isAtEnd: Bool {
        currentIndex >= elements.count
    }

    private static let atEndDescription = "Unkeyed container is at end"

    private mutating func nextValue() throws -> JSONValue {
        guard !isAtEnd else {
            let context = DecodingError.Context(
                codingPath: codingPath,
                debugDescription: Self.atEndDescription
            )
            throw DecodingError.valueNotFound(JSONValue.self, context)
        }
        defer { currentIndex += 1 }
        return elements[currentIndex]
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else {
            let context = DecodingError.Context(
                codingPath: codingPath,
                debugDescription: Self.atEndDescription
            )
            throw DecodingError.valueNotFound(JSONValue.self, context)
        }
        if case .null = elements[currentIndex] {
            currentIndex += 1
            return true
        }
        return false
    }

    mutating func decode<T: Decodable>(_: T.Type) throws -> T {
        let index = currentIndex
        let child = try LosslessJSONValueDecoder(
            value: nextValue(),
            codingPath: codingPath + [AnyCodingKey(intValue: index)]
        )
        return try T(from: child)
    }

    mutating func decode(_: Bool.Type) throws -> Bool {
        try LosslessJSONPrimitive.bool(nextValue(), codingPath: codingPath)
    }

    mutating func decode(_: String.Type) throws -> String {
        try LosslessJSONPrimitive.string(nextValue(), codingPath: codingPath)
    }

    mutating func decode(_: Double.Type) throws -> Double {
        try LosslessJSONPrimitive.double(nextValue(), codingPath: codingPath)
    }

    mutating func decode(_: Float.Type) throws -> Float {
        try LosslessJSONPrimitive.float(nextValue(), codingPath: codingPath)
    }

    mutating func decode(_: Int.Type) throws -> Int {
        try LosslessJSONPrimitive.integer(nextValue(), codingPath: codingPath)
    }

    mutating func decode(_: Int8.Type) throws -> Int8 {
        try LosslessJSONPrimitive.integer(nextValue(), codingPath: codingPath)
    }

    mutating func decode(_: Int16.Type) throws -> Int16 {
        try LosslessJSONPrimitive.integer(nextValue(), codingPath: codingPath)
    }

    mutating func decode(_: Int32.Type) throws -> Int32 {
        try LosslessJSONPrimitive.integer(nextValue(), codingPath: codingPath)
    }

    mutating func decode(_: Int64.Type) throws -> Int64 {
        try LosslessJSONPrimitive.integer(nextValue(), codingPath: codingPath)
    }

    mutating func decode(_: UInt.Type) throws -> UInt {
        try LosslessJSONPrimitive.integer(nextValue(), codingPath: codingPath)
    }

    mutating func decode(_: UInt8.Type) throws -> UInt8 {
        try LosslessJSONPrimitive.integer(nextValue(), codingPath: codingPath)
    }

    mutating func decode(_: UInt16.Type) throws -> UInt16 {
        try LosslessJSONPrimitive.integer(nextValue(), codingPath: codingPath)
    }

    mutating func decode(_: UInt32.Type) throws -> UInt32 {
        try LosslessJSONPrimitive.integer(nextValue(), codingPath: codingPath)
    }

    mutating func decode(_: UInt64.Type) throws -> UInt64 {
        try LosslessJSONPrimitive.integer(nextValue(), codingPath: codingPath)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy _: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let index = currentIndex
        guard case let .object(dict) = try nextValue() else {
            throw LosslessJSONPrimitive.typeMismatch([String: JSONValue].self, .null, codingPath)
        }
        let container = LosslessJSONKeyedDecodingContainer<NestedKey>(
            dictionary: dict,
            codingPath: codingPath + [AnyCodingKey(intValue: index)]
        )
        return KeyedDecodingContainer(container)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        let index = currentIndex
        guard case let .array(items) = try nextValue() else {
            throw LosslessJSONPrimitive.typeMismatch([JSONValue].self, .null, codingPath)
        }
        return LosslessJSONUnkeyedDecodingContainer(
            elements: items,
            codingPath: codingPath + [AnyCodingKey(intValue: index)]
        )
    }

    mutating func superDecoder() throws -> Decoder {
        let index = currentIndex
        return try LosslessJSONValueDecoder(
            value: nextValue(),
            codingPath: codingPath + [AnyCodingKey(intValue: index)]
        )
    }
}

struct LosslessJSONSingleValueDecodingContainer: SingleValueDecodingContainer {
    let value: JSONValue
    let codingPath: [CodingKey]

    func decodeNil() -> Bool {
        if case .null = value {
            return true
        }
        return false
    }

    func decode(_: Bool.Type) throws -> Bool {
        try LosslessJSONPrimitive.bool(value, codingPath: codingPath)
    }

    func decode(_: String.Type) throws -> String {
        try LosslessJSONPrimitive.string(value, codingPath: codingPath)
    }

    func decode(_: Double.Type) throws -> Double {
        try LosslessJSONPrimitive.double(value, codingPath: codingPath)
    }

    func decode(_: Float.Type) throws -> Float {
        try LosslessJSONPrimitive.float(value, codingPath: codingPath)
    }

    func decode(_: Int.Type) throws -> Int {
        try LosslessJSONPrimitive.integer(value, codingPath: codingPath)
    }

    func decode(_: Int8.Type) throws -> Int8 {
        try LosslessJSONPrimitive.integer(value, codingPath: codingPath)
    }

    func decode(_: Int16.Type) throws -> Int16 {
        try LosslessJSONPrimitive.integer(value, codingPath: codingPath)
    }

    func decode(_: Int32.Type) throws -> Int32 {
        try LosslessJSONPrimitive.integer(value, codingPath: codingPath)
    }

    func decode(_: Int64.Type) throws -> Int64 {
        try LosslessJSONPrimitive.integer(value, codingPath: codingPath)
    }

    func decode(_: UInt.Type) throws -> UInt {
        try LosslessJSONPrimitive.integer(value, codingPath: codingPath)
    }

    func decode(_: UInt8.Type) throws -> UInt8 {
        try LosslessJSONPrimitive.integer(value, codingPath: codingPath)
    }

    func decode(_: UInt16.Type) throws -> UInt16 {
        try LosslessJSONPrimitive.integer(value, codingPath: codingPath)
    }

    func decode(_: UInt32.Type) throws -> UInt32 {
        try LosslessJSONPrimitive.integer(value, codingPath: codingPath)
    }

    func decode(_: UInt64.Type) throws -> UInt64 {
        try LosslessJSONPrimitive.integer(value, codingPath: codingPath)
    }

    func decode<T: Decodable>(_: T.Type) throws -> T {
        let child = LosslessJSONValueDecoder(value: value, codingPath: codingPath)
        return try T(from: child)
    }
}
