import Foundation

extension StoryNarrativeLocalization {
    /// The server's `cardNameVar` sends `name` (English title) with `__name` (card code), and
    /// `investigatorNameVar` sends `iname` with `__iname`. The web's `handleI18n` swaps the
    /// title for the localized DB card name before interpolating; this does the same from the
    /// verified catalog's `cardNames.<code>` entries.
    ///
    /// The code is looked up as one exact key: the catalog generator already publishes the
    /// `<code>b` alias and the bare code → `<code>a` mapping, so the client adds no suffix logic.
    ///
    /// Fallback (accepted deviation from the web, which only has the device locale's DB): the
    /// resolver walks the catalog locale chain, so a code missing from the device locale's
    /// pack uses the `en` pack, and a code missing there too keeps the server-sent name. A
    /// substitution only ever changes a variable value; an unresolved label key still fails.
    static func localizingCardNameVariables(
        _ variables: JSONValue,
        resolver: LocaleCatalogResolver?
    ) -> JSONValue {
        guard let resolver, case var .object(values) = variables else { return variables }
        for (nameKey, localized) in localizedCardNames(in: values, resolver: resolver) {
            values[nameKey] = .string(localized)
        }
        return .object(values)
    }

    /// The localized replacement for each `name`/`iname` variable that
    /// `localizingCardNameVariables` would substitute, keyed by that variable's name. Shared
    /// with the game log, which also has to replace the variable's rich value.
    static func localizedCardNames(
        in values: [String: JSONValue],
        resolver: LocaleCatalogResolver
    ) -> [String: String] {
        var result: [String: String] = [:]
        for (nameKey, codeKey) in [("name", "__name"), ("iname", "__iname")] {
            guard case let .string(name)? = values[nameKey], !name.isEmpty,
                  case let .string(code)? = values[codeKey], !code.isEmpty,
                  case let .success(nodes) = resolver.render(
                      key: "cardNames.\(code)", variables: .object([:])
                  )
            else { continue }
            let localized = nodes.map(\.plainText).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !localized.isEmpty {
                result[nameKey] = localized
            }
        }
        return result
    }
}
