/// A validated, category-scoped identifier for an asset path segment.
///
/// Every instance is constructed through a category-specific factory that
/// enforces that category's exact grammar, derived from the pinned upstream
/// web client and backend identifier formats (see the doc comments on each
/// factory). Construction never sanitizes a hostile value into a different
/// asset: any input outside the grammar throws rather than being coerced.
///
/// The validated ``rawValue`` is safe to use as a single path segment: it can
/// never contain `/`, `\`, `..`, control characters, `%`, whitespace, or any
/// URL userinfo/query/fragment delimiter, because the allowed character sets
/// below never include them.
struct AssetIdentifier: Sendable, Equatable, Hashable {
    let rawValue: String

    private init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension AssetIdentifier {
    /// A card art code, e.g. `"01001"`, `"01001b"`, `"x05184"`, or a mutated
    /// variant `"04105_Mutated21"`.
    ///
    /// Grammar (see `Resources/AssetDigests/PROVENANCE.md` for how this was
    /// derived from ~8,000 real pinned upstream digest entries):
    /// - A base token that is either:
    ///   - 2–6 ASCII digits, optionally followed by 1–2 lowercase ASCII
    ///     letters (official/homebrew card codes and side/disambiguation
    ///     suffixes), or
    ///   - the literal `x` followed by 1–16 lowercase ASCII letters or
    ///     digits (special numbered/named variants such as `x05184` or
    ///     `xbetween`).
    /// - Optionally followed by `_Mutated` and 1–3 ASCII digits (mutated
    ///   asset art).
    ///
    /// Total length is capped at 40 characters as a defensive bound.
    static func cardCode(_ raw: String) throws -> AssetIdentifier {
        guard raw.count <= 40, let value = parseCardCode(raw) else {
            throw AssetError.invalidIdentifier(field: "cardCode")
        }
        return AssetIdentifier(rawValue: value)
    }

    /// A campaign, scenario, or box identifier, e.g. `"01"`, `"03276a"`,
    /// `"60101"`. Shares the base card-code grammar (without the mutation
    /// suffix, which only applies to player-card art).
    static func setOrBoxCode(_ raw: String) throws -> AssetIdentifier {
        guard raw.count <= 40, let value = parseBaseCode(raw) else {
            throw AssetError.invalidIdentifier(field: "setOrBoxCode")
        }
        return AssetIdentifier(rawValue: value)
    }

    /// A homebrew campaign/scenario/box directory slug, e.g.
    /// `"circus-ex-mortis"`, `"dark-matter"`.
    ///
    /// Grammar: lowercase ASCII letters and digits, hyphen-separated
    /// segments, each segment non-empty and starting with a letter. Length
    /// 1–64.
    static func homebrewSlug(_ raw: String) throws -> AssetIdentifier {
        guard isValidHomebrewSlug(raw) else {
            throw AssetError.invalidIdentifier(field: "homebrewSlug")
        }
        return AssetIdentifier(rawValue: raw)
    }

    /// A homebrew chaos-token key, e.g. `"moon"` from the slug
    /// `":circus-ex-mortis:moon"`.
    ///
    /// Grammar: lowercase ASCII letters, digits, and hyphens only, 1–64
    /// characters, not starting or ending with a hyphen.
    static func homebrewTokenKey(_ raw: String) throws -> AssetIdentifier {
        guard isValidSlugLikeToken(raw) else {
            throw AssetError.invalidIdentifier(field: "homebrewTokenKey")
        }
        return AssetIdentifier(rawValue: raw)
    }

    /// A custom scenario back filename's base name (without extension), e.g.
    /// `"back_artifact"`, `"children_of_blood"` (from `cdMeta.customBack` in
    /// the backend card definitions, which supply the extension alongside).
    ///
    /// Grammar: starts with a lowercase ASCII letter, followed by lowercase
    /// ASCII letters, digits, underscores, or hyphens; length 1–64.
    static func backSlug(_ raw: String) throws -> AssetIdentifier {
        guard isValidBackSlug(raw) else {
            throw AssetError.invalidIdentifier(field: "backSlug")
        }
        return AssetIdentifier(rawValue: raw)
    }
}

// MARK: - Backend `CardCode` conversion

/// The result of interpreting a typed backend ``CardCode`` (e.g. `c01001`,
/// or the homebrew form `c:dark-matter:151`) as an art asset location.
enum AssetArtworkIdentifier: Sendable, Equatable, Hashable {
    /// An official card's own art identifier, e.g. from `c01001`.
    case official(AssetIdentifier)
    /// A homebrew card's campaign slug and art identifier, e.g. from
    /// `c:circus-ex-mortis:151`.
    case homebrew(campaign: AssetIdentifier, art: AssetIdentifier)
}

extension AssetIdentifier {
    /// Converts a typed backend ``CardCode`` into the identifier(s) needed
    /// to build a ``AssetCategory/card(_:_:)`` or
    /// ``AssetCategory/homebrewCard(campaign:art:)`` asset key, applying
    /// exactly the same normalization the web client applies (see
    /// `frontend/src/utils/cards.ts`'s handling of `card`/`portrait`/
    /// other/resolved-side art paths): strip *exactly one* leading `c` —
    /// the Aeson prefix ``CardCode`` itself already guarantees is present
    /// — never more, so a second, literal `c` anywhere later in the
    /// payload (for example the start of a homebrew campaign slug like
    /// `circus-ex-mortis`) is preserved as real content rather than
    /// stripped away too. After that single strip, a payload beginning
    /// with `:` is the homebrew `:campaign:code` form; everything else is
    /// an official numeric/`x`-prefixed card code, validated by
    /// ``cardCode(_:)`` exactly as any other card art identifier is.
    ///
    /// - Throws: ``AssetError/invalidIdentifier(field:)`` if the payload
    ///   after stripping the prefix is empty, the homebrew form does not
    ///   split into exactly two non-empty `:`-delimited components, or
    ///   either resulting segment fails its own grammar
    ///   (``homebrewSlug(_:)`` for the campaign, ``cardCode(_:)`` for the
    ///   art code).
    static func artwork(from cardCode: CardCode) throws -> AssetArtworkIdentifier {
        let raw = cardCode.rawValue
        // `CardCode.init` already guarantees `raw` starts with `c` and has
        // a non-empty payload after it; re-checking here is cheap
        // defense-in-depth against that invariant ever changing without
        // this call site being revisited.
        guard raw.first == "c" else {
            throw AssetError.invalidIdentifier(field: "cardCode")
        }
        let payload = String(raw.dropFirst())
        guard !payload.isEmpty else {
            throw AssetError.invalidIdentifier(field: "cardCode")
        }
        guard payload.first == ":" else {
            return try .official(AssetIdentifier.cardCode(payload))
        }
        let components = payload.dropFirst().split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard components.count == 2, !components[0].isEmpty, !components[1].isEmpty else {
            throw AssetError.invalidIdentifier(field: "cardCode")
        }
        let campaign = try AssetIdentifier.homebrewSlug(String(components[0]))
        let art = try AssetIdentifier.cardCode(String(components[1]))
        return .homebrew(campaign: campaign, art: art)
    }
}

// MARK: - Grammar implementation

private extension AssetIdentifier {
    /// Parses the full card-code grammar including the optional
    /// `_Mutated<digits>` suffix. Returns `nil` (never partially matches) if
    /// any character falls outside the grammar or trailing input remains.
    static func parseCardCode(_ raw: String) -> String? {
        var chars = Array(raw)[...]
        guard let base = consumeBaseCode(&chars) else { return nil }
        var result = base
        if chars.first == "_" {
            chars.removeFirst()
            guard chars.prefix(7).elementsEqual("Mutated") else { return nil }
            chars.removeFirst(7)
            var digits = ""
            while let character = chars.first, character.isASCII, character.isNumber {
                digits.append(character)
                chars.removeFirst()
            }
            guard (1 ... 3).contains(digits.count) else { return nil }
            result += "_Mutated" + digits
        }
        guard chars.isEmpty else { return nil }
        return result
    }

    /// Parses just the base code (no mutation suffix); used by
    /// ``parseCardCode(_:)`` and directly by ``setOrBoxCode(_:)``.
    static func parseBaseCode(_ raw: String) -> String? {
        var chars = Array(raw)[...]
        guard let base = consumeBaseCode(&chars), chars.isEmpty else { return nil }
        return base
    }

    /// Consumes either `[0-9]{2,6}([a-z]{1,2})?` or `x[a-z0-9]{1,16}` from
    /// the front of `chars`, returning the consumed substring, or `nil` if
    /// the prefix does not match either form.
    static func consumeBaseCode(_ chars: inout ArraySlice<Character>) -> String? {
        if chars.first == "x" {
            var rest = chars
            rest.removeFirst()
            var token = "x"
            while let character = rest.first, isXTokenCharacter(character) {
                token.append(character)
                rest.removeFirst()
            }
            guard (2 ... 17).contains(token.count) else { return nil }
            chars = rest
            return token
        }

        var digits = ""
        var rest = chars
        while let character = rest.first, character.isASCII, character.isNumber {
            digits.append(character)
            rest.removeFirst()
        }
        guard (2 ... 6).contains(digits.count) else { return nil }

        var letters = ""
        while let character = rest.first, isLowercaseASCIILetter(character) {
            letters.append(character)
            rest.removeFirst()
            if letters.count == 2 {
                break
            }
        }
        chars = rest
        return digits + letters
    }

    /// A valid character within an `x`-prefixed homebrew token
    /// (`[a-z0-9]`), restricted to ASCII.
    private static func isXTokenCharacter(_ character: Character) -> Bool {
        character.isASCII && ((character.isLowercase && character.isLetter) || character.isNumber)
    }

    /// A valid lowercase ASCII letter, used for the optional side-letter
    /// suffix of a numeric card code.
    private static func isLowercaseASCIILetter(_ character: Character) -> Bool {
        character.isASCII && character.isLowercase && character.isLetter
    }

    static func isValidHomebrewSlug(_ raw: String) -> Bool {
        guard (1 ... 64).contains(raw.count) else { return false }
        let segments = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard !segments.isEmpty else { return false }
        for segment in segments {
            guard let first = segment.first, first.isASCII, first.isLowercase, first.isLetter
            else { return false }
            guard segment
                .allSatisfy({ $0.isASCII && (($0.isLowercase && $0.isLetter) || $0.isNumber) })
            else { return false }
        }
        return true
    }

    static func isValidSlugLikeToken(_ raw: String) -> Bool {
        guard (1 ... 64).contains(raw.count) else { return false }
        guard let first = raw.first, let last = raw.last, first != "-", last != "-" else {
            return false
        }
        return raw
            .allSatisfy {
                $0.isASCII && (($0.isLowercase && $0.isLetter) || $0.isNumber || $0 == "-")
            }
    }

    static func isValidBackSlug(_ raw: String) -> Bool {
        guard (1 ... 64).contains(raw.count) else { return false }
        guard let first = raw.first, first.isASCII, first.isLowercase, first.isLetter else {
            return false
        }
        return raw.allSatisfy {
            $0.isASCII && (($0.isLowercase && $0.isLetter) || $0.isNumber || $0 == "_" || $0 == "-")
        }
    }
}
