extension FlavorTextEntry {
    /// `FootnoteEntry.number` is a Haskell `Int`, so only a whole JSON number is accepted.
    static func footnoteNumber(_ value: JSONValue?) -> Int? {
        guard case let .number(number)? = value,
              let magnitude = number.wholeNumberMagnitude,
              let parsedMagnitude = Int(magnitude)
        else { return nil }
        return number.sign == .minus ? -parsedMagnitude : parsedMagnitude
    }
}
