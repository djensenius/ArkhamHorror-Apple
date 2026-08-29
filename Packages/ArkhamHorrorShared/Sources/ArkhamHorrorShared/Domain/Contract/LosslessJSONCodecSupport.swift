import Foundation

/// A `CodingKey` for coding-path bookkeeping only (unkeyed container element indices);
/// never used to look anything up.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init(intValue: Int) {
        stringValue = "Index \(intValue)"
        self.intValue = intValue
    }
}

/// Shared `JSONValue` -> fixed-precision-primitive conversions used by every
/// `LosslessJSON*Container`. Only these coarse primitives ever go through a fixed-precision
/// type; `JSONNumber`/`JSONValue` fields always decode through the generic `Decodable`
/// path instead, which keeps their exact original precision (see
/// ``LosslessJSONNumberSource``).
enum LosslessJSONPrimitive {
    static func typeMismatch(
        _ expected: Any.Type,
        _ value: JSONValue,
        _ codingPath: [CodingKey]
    ) -> DecodingError {
        let description = "Expected \(expected), got \(value.kindDescription)"
        return DecodingError.typeMismatch(
            expected,
            DecodingError.Context(codingPath: codingPath, debugDescription: description)
        )
    }

    static func bool(_ value: JSONValue, codingPath: [CodingKey]) throws -> Bool {
        guard case let .bool(result) = value else {
            throw typeMismatch(Bool.self, value, codingPath)
        }
        return result
    }

    static func string(_ value: JSONValue, codingPath: [CodingKey]) throws -> String {
        guard case let .string(result) = value else {
            throw typeMismatch(String.self, value, codingPath)
        }
        return result
    }

    static func double(_ value: JSONValue, codingPath: [CodingKey]) throws -> Double {
        guard case let .number(number) = value, let result = Double(number.description) else {
            throw typeMismatch(Double.self, value, codingPath)
        }
        return try boundedFloatingResult(result, number: number, codingPath: codingPath)
    }

    static func float(_ value: JSONValue, codingPath: [CodingKey]) throws -> Float {
        guard case let .number(number) = value, let result = Float(number.description) else {
            throw typeMismatch(Float.self, value, codingPath)
        }
        return try boundedFloatingResult(result, number: number, codingPath: codingPath)
    }

    /// Rejects the two ways `BinaryFloatingPoint.init?(String)` silently loses information
    /// at the extremes rather than failing: an out-of-range magnitude (`"1e999"`) that
    /// parses to `.infinity`/`-.infinity`, and a nonzero source value so far below the
    /// smallest representable magnitude that it silently underflows to `0`
    /// (`"1e-999"` -> `0.0`). A source value that is genuinely zero still decodes to (signed)
    /// zero; only a *nonzero* source collapsing to zero is treated as data loss. Ordinary
    /// finite rounding (a value that fits, just not exactly) is always allowed — this only
    /// guards the two failure modes that would otherwise be silent.
    private static func boundedFloatingResult<T: BinaryFloatingPoint>(
        _ result: T,
        number: JSONNumber,
        codingPath: [CodingKey]
    ) throws -> T {
        guard result.isFinite else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "\(number) overflows \(T.self)'s representable range"
                )
            )
        }
        guard result != 0 || number.isZero else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "\(number) underflows to zero in \(T.self)"
                )
            )
        }
        return result
    }

    static func integer<T: FixedWidthInteger>(
        _ value: JSONValue,
        codingPath: [CodingKey]
    ) throws -> T {
        guard case let .number(number) = value, let magnitude = number.wholeNumberMagnitude else {
            throw typeMismatch(T.self, value, codingPath)
        }
        let text = (number.sign == .minus && magnitude != "0") ? "-\(magnitude)" : magnitude
        guard let result = T(text) else {
            let description = "\(text) does not fit in \(T.self)"
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: codingPath, debugDescription: description)
            )
        }
        return result
    }
}

// Decodes a `Decodable` type directly from an already-parsed ``JSONValue`` tree, never
// through Foundation's `JSONDecoder`. Conforms to ``LosslessJSONNumberSource``, exposing
// the exact number at the decoder's current position — the property that makes
// ``ContractJSON/decode(_:from:)`` a genuinely lossless contract decode path rather than a
// thin wrapper that still loses precision internally.
