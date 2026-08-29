import Foundation

enum LosslessJSONSerializer {
    static func serialize(_ value: JSONValue) -> Data {
        var output: [UInt8] = []
        write(value, into: &output)
        return Data(output)
    }

    private static func write(_ value: JSONValue, into output: inout [UInt8]) {
        switch value {
        case .null:
            output.append(contentsOf: "null".utf8)
        case let .bool(bool):
            output.append(contentsOf: (bool ? "true" : "false").utf8)
        case let .number(number):
            output.append(contentsOf: number.description.utf8)
        case let .string(string):
            writeString(string, into: &output)
        case let .array(elements):
            output.append(0x5B)
            for (index, element) in elements.enumerated() {
                if index > 0 {
                    output.append(0x2C)
                }
                write(element, into: &output)
            }
            output.append(0x5D)
        case let .object(dictionary):
            output.append(0x7B)
            for (index, key) in dictionary.keys.sorted().enumerated() {
                if index > 0 {
                    output.append(0x2C)
                }
                writeString(key, into: &output)
                output.append(0x3A)
                write(dictionary[key] ?? .null, into: &output)
            }
            output.append(0x7D)
        }
    }

    private static func writeString(_ string: String, into output: inout [UInt8]) {
        output.append(0x22)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output.append(contentsOf: "\\\"".utf8)
            case "\\": output.append(contentsOf: "\\\\".utf8)
            case "\n": output.append(contentsOf: "\\n".utf8)
            case "\r": output.append(contentsOf: "\\r".utf8)
            case "\t": output.append(contentsOf: "\\t".utf8)
            default:
                if scalar.value < 0x20 {
                    output.append(contentsOf: String(format: "\\u%04x", scalar.value).utf8)
                } else {
                    output.append(contentsOf: String(scalar).utf8)
                }
            }
        }
        output.append(0x22)
    }
}

/// The canonical, lossless decode/encode path for contract JSON payloads (catalog, deck,
/// and game-lifecycle/list data). Unlike a standard `JSONDecoder`/`JSONEncoder`, this path
/// never rounds or rejects a JSON number: every ``JSONNumber``/``JSONValue`` field decoded
/// or encoded through it retains its exact original precision, and ``rawToken``-bearing
/// numbers re-encode byte-for-byte. A network client consuming these contract endpoints
/// should decode/encode exclusively through this type, not through
/// `JSONDecoder`/`JSONEncoder` directly.
enum ContractJSON {
    static func decode<T: Decodable>(_: T.Type, from data: Data) throws -> T {
        let value = try LosslessJSONParser.parse(data)
        let decoder = LosslessJSONValueDecoder(value: value, codingPath: [])
        return try T(from: decoder)
    }

    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = LosslessJSONValueEncoder(codingPath: [])
        try value.encode(to: encoder)
        return LosslessJSONSerializer.serialize(encoder.encodedValue)
    }
}
