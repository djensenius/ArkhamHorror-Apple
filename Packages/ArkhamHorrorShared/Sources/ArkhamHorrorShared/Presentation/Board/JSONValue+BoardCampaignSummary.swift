extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var booleanValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var integerValue: Int? {
        guard case let .number(value) = self,
              let magnitude = value.wholeNumberMagnitude,
              let int64 = Int64(magnitude)
        else { return nil }
        let signed = value.sign == .minus ? -int64 : int64
        return Int(exactly: signed)
    }
}
