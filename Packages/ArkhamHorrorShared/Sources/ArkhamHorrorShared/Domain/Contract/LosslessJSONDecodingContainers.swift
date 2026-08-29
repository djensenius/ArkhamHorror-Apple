import Foundation

// `LosslessJSONUnkeyedDecodingContainer`/`LosslessJSONSingleValueDecodingContainer` live
// here, separate from `LosslessJSONValueDecoder`/`LosslessJSONKeyedDecodingContainer` in
// `LosslessJSONDecoding.swift`, purely to keep both files under SwiftLint's 400-line
// file-length limit. Neither type here depends on anything file-private to that file: both
// are plain, fully `internal` structs referencing only other `internal`-or-wider symbols
// (`LosslessJSONValueDecoder`, `LosslessJSONKeyedDecodingContainer`, `LosslessJSONPrimitive`,
// `AnyCodingKey`), so the split has no effect on access control or behavior.

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

    /// Builds the `codingPath` for an error at unkeyed `index`, including that index so
    /// diagnostics (e.g. for reads past the end, or scalar type mismatches) always report
    /// the failing array position, matching `decode<T: Decodable>` and the nested-container
    /// paths below.
    private func indexedCodingPath(_ index: Int) -> [CodingKey] {
        codingPath + [AnyCodingKey(intValue: index)]
    }

    private mutating func nextValue() throws -> JSONValue {
        guard !isAtEnd else {
            let context = DecodingError.Context(
                codingPath: indexedCodingPath(currentIndex),
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
                codingPath: indexedCodingPath(currentIndex),
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
            codingPath: indexedCodingPath(index)
        )
        return try T(from: child)
    }

    mutating func decode(_: Bool.Type) throws -> Bool {
        let index = currentIndex
        return try LosslessJSONPrimitive.bool(nextValue(), codingPath: indexedCodingPath(index))
    }

    mutating func decode(_: String.Type) throws -> String {
        let index = currentIndex
        return try LosslessJSONPrimitive.string(nextValue(), codingPath: indexedCodingPath(index))
    }

    mutating func decode(_: Double.Type) throws -> Double {
        let index = currentIndex
        return try LosslessJSONPrimitive.double(nextValue(), codingPath: indexedCodingPath(index))
    }

    mutating func decode(_: Float.Type) throws -> Float {
        let index = currentIndex
        return try LosslessJSONPrimitive.float(nextValue(), codingPath: indexedCodingPath(index))
    }

    mutating func decode(_: Int.Type) throws -> Int {
        let index = currentIndex
        return try LosslessJSONPrimitive.integer(nextValue(), codingPath: indexedCodingPath(index))
    }

    mutating func decode(_: Int8.Type) throws -> Int8 {
        let index = currentIndex
        return try LosslessJSONPrimitive.integer(nextValue(), codingPath: indexedCodingPath(index))
    }

    mutating func decode(_: Int16.Type) throws -> Int16 {
        let index = currentIndex
        return try LosslessJSONPrimitive.integer(nextValue(), codingPath: indexedCodingPath(index))
    }

    mutating func decode(_: Int32.Type) throws -> Int32 {
        let index = currentIndex
        return try LosslessJSONPrimitive.integer(nextValue(), codingPath: indexedCodingPath(index))
    }

    mutating func decode(_: Int64.Type) throws -> Int64 {
        let index = currentIndex
        return try LosslessJSONPrimitive.integer(nextValue(), codingPath: indexedCodingPath(index))
    }

    mutating func decode(_: UInt.Type) throws -> UInt {
        let index = currentIndex
        return try LosslessJSONPrimitive.integer(nextValue(), codingPath: indexedCodingPath(index))
    }

    mutating func decode(_: UInt8.Type) throws -> UInt8 {
        let index = currentIndex
        return try LosslessJSONPrimitive.integer(nextValue(), codingPath: indexedCodingPath(index))
    }

    mutating func decode(_: UInt16.Type) throws -> UInt16 {
        let index = currentIndex
        return try LosslessJSONPrimitive.integer(nextValue(), codingPath: indexedCodingPath(index))
    }

    mutating func decode(_: UInt32.Type) throws -> UInt32 {
        let index = currentIndex
        return try LosslessJSONPrimitive.integer(nextValue(), codingPath: indexedCodingPath(index))
    }

    mutating func decode(_: UInt64.Type) throws -> UInt64 {
        let index = currentIndex
        return try LosslessJSONPrimitive.integer(nextValue(), codingPath: indexedCodingPath(index))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy _: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let index = currentIndex
        let elementCodingPath = indexedCodingPath(index)
        let element = try nextValue()
        guard case let .object(dict) = element else {
            throw LosslessJSONPrimitive.typeMismatch(
                [String: JSONValue].self,
                element,
                elementCodingPath
            )
        }
        let container = LosslessJSONKeyedDecodingContainer<NestedKey>(
            dictionary: dict,
            codingPath: elementCodingPath
        )
        return KeyedDecodingContainer(container)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        let index = currentIndex
        let elementCodingPath = indexedCodingPath(index)
        let element = try nextValue()
        guard case let .array(items) = element else {
            throw LosslessJSONPrimitive.typeMismatch([JSONValue].self, element, elementCodingPath)
        }
        return LosslessJSONUnkeyedDecodingContainer(
            elements: items,
            codingPath: elementCodingPath
        )
    }

    mutating func superDecoder() throws -> Decoder {
        let index = currentIndex
        return try LosslessJSONValueDecoder(
            value: nextValue(),
            codingPath: indexedCodingPath(index)
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
