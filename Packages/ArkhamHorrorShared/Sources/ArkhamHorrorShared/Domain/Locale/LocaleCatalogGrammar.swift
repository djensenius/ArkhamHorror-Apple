import Foundation

/// Every ASCII grammar the backend's locale-catalog boundary pins, transcribed by hand from
/// the governed schemas rather than evaluated as a regular expression.
///
/// The backend states the reason these are spelled out character-by-character
/// (`contracts/README.md`, "Every grammar is ASCII"): digests, revisions, locale tags, hosts
/// and ports are compared by clients *as strings*, so a character that merely looks like a
/// digit or a letter must be refused rather than folded. Swift's `Character.isLetter`,
/// `isNumber`, and `lowercased()` are all Unicode-aware, so an Arabic-Indic digit, a
/// fullwidth digit, a Cyrillic confusable, or a KELVIN SIGN would each pass a naive check
/// and then compare unequal to the ASCII value the server actually published. Every
/// predicate below therefore works on `UTF8View` bytes and closed ASCII ranges only.
///
/// The schemas these mirror are:
/// - `contracts/schemas/capabilities.schema.json` (`$defs.localeCatalog`, `$defs.locale`)
/// - `frontend/schemas/locale-catalog/v1/manifest.schema.json`
/// - `frontend/schemas/locale-catalog/v1/chunk.schema.json`
enum LocaleCatalogGrammar {
    // MARK: - Primitive byte classes

    private static func isDigit(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
    }

    private static func isLowerHex(_ byte: UInt8) -> Bool {
        isDigit(byte) || (0x61 ... 0x66).contains(byte)
    }

    private static func isLowerAlpha(_ byte: UInt8) -> Bool {
        (0x61 ... 0x7A).contains(byte)
    }

    private static func isUpperAlpha(_ byte: UInt8) -> Bool {
        (0x41 ... 0x5A).contains(byte)
    }

    private static func isAlpha(_ byte: UInt8) -> Bool {
        isLowerAlpha(byte) || isUpperAlpha(byte)
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        isAlpha(byte) || isDigit(byte)
    }

    private static func isLowerAlphanumeric(_ byte: UInt8) -> Bool {
        isLowerAlpha(byte) || isDigit(byte)
    }

    /// `[A-Za-z0-9._~-]`: the unreserved path-segment character class both `manifestUrl`
    /// branches use.
    private static func isUnreservedPathByte(_ byte: UInt8) -> Bool {
        isAlphanumeric(byte) || byte == 0x2E || byte == 0x5F || byte == 0x7E || byte == 0x2D
    }

    /// Whether every byte of `text` is ASCII (< 0x80). Checked before any other predicate so
    /// a multi-byte scalar can never be silently split into bytes that pass a byte test.
    static func isASCII(_ text: String) -> Bool {
        text.utf8.allSatisfy { $0 < 0x80 }
    }

    /// ASCII-only lowercasing for keys that the catalog compares case-insensitively.
    /// Returns `nil` for a non-ASCII input rather than using Unicode case folding.
    static func asciiLowercased(_ text: String) -> String? {
        guard isASCII(text) else { return nil }
        let bytes = text.utf8.map { byte in
            (0x41 ... 0x5A).contains(byte) ? byte + 0x20 : byte
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    // MARK: - Digests, revisions, counts

    /// `^[0-9a-f]{64}` — the manifest/chunk `sha256` and `manifestSha256` grammar.
    static func isSHA256Hex(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count == 64 && bytes.allSatisfy(isLowerHex)
    }

    /// `^1\.[0-9a-f]{32}` — the only catalog revision spelling a v1 server publishes.
    ///
    /// The major component is pinned to a canonical `1` (never `01`, `00`, or `2`) exactly
    /// as `capabilities.schema.json` does, so a client comparing revisions as strings can
    /// never read two spellings of one revision as two different catalogs.
    static func isCatalogRevision(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 34, bytes[0] == 0x31, bytes[1] == 0x2E else { return false }
        return bytes[2...].allSatisfy(isLowerHex)
    }

    /// The immutable revision manifest path `catalogRevision` derives:
    /// `^/locale-catalog/r/1\.[0-9a-f]{32}/manifest\.json`.
    static func revisionManifestPath(for catalogRevision: String) -> String {
        "/locale-catalog/r/\(catalogRevision)/manifest.json"
    }

    /// `^/locale-catalog/c/[0-9a-f]{64}\.json` with the digest bound to the descriptor's own
    /// `sha256`, which is what makes a chunk URL content-addressed rather than merely
    /// well-shaped.
    static func chunkPath(forDigest sha256: String) -> String {
        "\(LocaleCatalogLimits.chunkPathPrefix)\(sha256).json"
    }

    // MARK: - Locales

    /// `capabilities.schema.json`'s `$defs.locale`: the canonical BCP-47 casing
    /// `Base.Api.Types.LocaleCatalog.canonicalLocaleTag` emits — lowercase language,
    /// titlecase four-letter script, uppercase two-letter region, lowercase everything else.
    ///
    /// The two negative lookaheads in the published pattern are what reject a *lowercase*
    /// two- or four-letter subtag (`en-us`, `zh-hant`) the server would have canonicalized
    /// before publishing it; they are transcribed here as the explicit
    /// `isNonCanonicalLowercaseSubtag` rejection.
    static func isCanonicalLocaleTag(_ text: String) -> Bool {
        guard text.utf8.count <= 64 else { return false }
        let subtags = splitASCII(text, separator: 0x2D)
        guard let language = subtags.first else { return false }
        guard (2 ... 3).contains(language.count), language.allSatisfy(isLowerAlpha) else {
            return false
        }
        return subtags.dropFirst().allSatisfy(isCanonicalLocaleSubtag)
    }

    private static func isCanonicalLocaleSubtag(_ subtag: [UInt8]) -> Bool {
        if subtag.count == 2, subtag.allSatisfy(isUpperAlpha) {
            return true
        }
        if subtag.count == 4, isUpperAlpha(subtag[0]), subtag[1...].allSatisfy(isLowerAlpha) {
            return true
        }
        guard (2 ... 8).contains(subtag.count), subtag.allSatisfy(isLowerAlphanumeric) else {
            return false
        }
        return !isNonCanonicalLowercaseSubtag(subtag)
    }

    /// A two- or four-letter all-lowercase subtag: the non-canonical spelling of a region or
    /// a script the server always emits in canonical case instead.
    private static func isNonCanonicalLowercaseSubtag(_ subtag: [UInt8]) -> Bool {
        (subtag.count == 2 || subtag.count == 4) && subtag.allSatisfy(isLowerAlpha)
    }

    /// The v1 catalog manifest/chunk `$defs.locale`, which is deliberately *looser* than the
    /// canonical advertisement grammar: `^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*`.
    ///
    /// Kept distinct on purpose. Loosening the advertised set to this grammar would let a
    /// manifest publish `en-us` alongside the advertised `en-US` and have a client treat
    /// them as one locale; requiring the canonical grammar here instead would reject a
    /// manifest the published schema accepts. Parity between the two documents is asserted
    /// separately, by exact string equality of the locale sets.
    static func isCatalogLocaleTag(_ text: String) -> Bool {
        guard text.utf8.count <= 64 else { return false }
        let subtags = splitASCII(text, separator: 0x2D)
        guard let language = subtags.first else { return false }
        guard (2 ... 3).contains(language.count), language.allSatisfy(isLowerAlpha) else {
            return false
        }
        return subtags.dropFirst().allSatisfy { subtag in
            (2 ... 8).contains(subtag.count) && subtag.allSatisfy(isAlphanumeric)
        }
    }

    /// The manifest's `languageResolution[].tag`: `^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*`.
    static func isLanguageResolutionTag(_ text: String) -> Bool {
        guard text.utf8.count <= 64 else { return false }
        let subtags = splitASCII(text, separator: 0x2D)
        guard let language = subtags.first else { return false }
        guard (2 ... 3).contains(language.count), language.allSatisfy(isAlpha) else {
            return false
        }
        return subtags.dropFirst().allSatisfy { subtag in
            (2 ... 8).contains(subtag.count) && subtag.allSatisfy(isAlphanumeric)
        }
    }

    // MARK: - Keys, packs, identifiers

    /// The chunk schema's `messageKey`: a dotted vue-i18n key whose segments may hold any
    /// character the locale sources use *except* a dot, path separator, control character,
    /// or the two private-use sentinels the generator reserves.
    ///
    /// Deliberately **not** ASCII-only: a message key is a lookup identifier drawn from
    /// translated source files, and the published grammar admits any other scalar. The
    /// exclusions are enforced on Unicode scalars rather than bytes for exactly that reason.
    static func isMessageKey(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 512 else { return false }
        var segmentLength = 0
        for scalar in text.unicodeScalars {
            if scalar == "." {
                guard segmentLength > 0 else { return false }
                segmentLength = 0
                continue
            }
            guard isMessageKeyScalar(scalar) else { return false }
            segmentLength += 1
        }
        return segmentLength > 0
    }

    private static func isMessageKeyScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00 ... 0x1F, 0x7F: false
        case 0x2F, 0x5C: false
        case 0xE000, 0xE001: false
        default: true
        }
    }

    /// `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}` — a chunk's pack identifier.
    static func isPackIdentifier(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (1 ... 64).contains(bytes.count), isAlphanumeric(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy { isAlphanumeric($0) || $0 == 0x5F || $0 == 0x2D }
    }

    /// `^[A-Za-z0-9_]{1,64}` — a declared variable name.
    static func isVariableName(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return (1 ... 64).contains(bytes.count)
            && bytes.allSatisfy { isAlphanumeric($0) || $0 == 0x5F }
    }

    /// `^[A-Za-z][A-Za-z0-9-]{0,63}` — a presentation style hint token.
    static func isStyleToken(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (1 ... 64).contains(bytes.count), isAlpha(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy { isAlphanumeric($0) || $0 == 0x2D }
    }

    /// `^(--)?[A-Za-z][A-Za-z0-9-]{0,31}` — an inline CSS property name.
    static func isStyleProperty(_ text: String) -> Bool {
        var bytes = Array(text.utf8)
        if bytes.count >= 2, bytes[0] == 0x2D, bytes[1] == 0x2D {
            bytes = Array(bytes.dropFirst(2))
        }
        guard (1 ... 32).contains(bytes.count), isAlpha(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy { isAlphanumeric($0) || $0 == 0x2D }
    }

    /// `^[A-Za-z0-9 .,%#()/_-]{1,64}` — an inline CSS value drawn from the closed grammar the
    /// generator already reduced to a safe charset. Never executed, only carried.
    static func isStyleValue(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (1 ... 64).contains(bytes.count) else { return false }
        let extra: Set<UInt8> = [0x20, 0x2E, 0x2C, 0x25, 0x23, 0x28, 0x29, 0x2F, 0x5F, 0x2D]
        return bytes.allSatisfy { isAlphanumeric($0) || extra.contains($0) }
    }

    /// `^[A-Za-z0-9_.:-]{1,64}` — an allowlisted `data-*` literal token.
    static func isDataToken(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (1 ... 64).contains(bytes.count) else { return false }
        return bytes.allSatisfy { isAlphanumeric($0) || $0 == 0x5F || $0 == 0x2E || $0 == 0x3A
            || $0 == 0x2D
        }
    }

    /// `^:?[A-Za-z0-9][A-Za-z0-9:_-]{1,31}` — a `cardRef` node's card code.
    static func isCardRefCode(_ text: String) -> Bool {
        var bytes = Array(text.utf8)
        if bytes.first == 0x3A {
            bytes = Array(bytes.dropFirst())
        }
        guard (2 ... 32).contains(bytes.count), isAlphanumeric(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy {
            isAlphanumeric($0) || $0 == 0x3A || $0 == 0x5F || $0 == 0x2D
        }
    }

    /// The semantic asset path an `image` node or a `url()` style declaration resolves to,
    /// always relative to the deployment's own `/img/arkham/` root and never an absolute or
    /// external URL: `^[A-Za-z0-9][A-Za-z0-9._/-]*\.(png|jpe?g|avif|svg|webp)`, with no `..`
    /// segment anywhere.
    static func isAssetPath(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (1 ... 248).contains(bytes.count), isAlphanumeric(bytes[0]) else { return false }
        guard bytes.allSatisfy({
            isAlphanumeric($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2F || $0 == 0x2D
        }) else { return false }
        guard !hasDotSegment(text) else { return false }
        let extensions = ["png", "jpg", "jpeg", "avif", "svg", "webp"]
        return extensions.contains { text.hasSuffix(".\($0)") }
    }

    /// The `(^|/)\.\.?(/|$)` rejection both the capabilities and manifest schemas apply: a
    /// `.` or `..` path segment anywhere makes the value invalid rather than something to
    /// normalize away.
    static func hasDotSegment(_ text: String) -> Bool {
        splitASCII(text, separator: 0x2F).contains { segment in
            segment == [0x2E] || segment == [0x2E, 0x2E]
        }
    }

    // MARK: - Helpers

    /// Splits `text`'s UTF-8 bytes on an ASCII `separator`, preserving empty components so a
    /// leading, trailing, or doubled separator is visible to the caller rather than elided.
    static func splitASCII(_ text: String, separator: UInt8) -> [[UInt8]] {
        var components: [[UInt8]] = []
        var current: [UInt8] = []
        for byte in text.utf8 {
            if byte == separator {
                components.append(current)
                current = []
            } else {
                current.append(byte)
            }
        }
        components.append(current)
        return components
    }

    /// A canonical decimal integer in `0...upperBound`: no sign, no leading zero (except the
    /// single digit `0`), ASCII digits only.
    static func canonicalInteger(_ bytes: [UInt8], upperBound: Int) -> Int? {
        guard !bytes.isEmpty, bytes.count <= 19, bytes.allSatisfy(isDigit) else { return nil }
        guard bytes.count == 1 || bytes[0] != 0x30 else { return nil }
        guard let text = String(bytes: bytes, encoding: .utf8),
              let value = Int(text),
              value <= upperBound
        else {
            return nil
        }
        return value
    }
}
