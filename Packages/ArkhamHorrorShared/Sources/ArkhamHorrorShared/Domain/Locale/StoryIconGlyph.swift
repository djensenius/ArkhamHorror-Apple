import Foundation

/// The web icon-font family names used by `frontend/src/styles/fonts.css`.
///
/// Provenance: fork commit 4203738708b0ad2d3cff426b4ce2e6b3d9904fec,
/// `frontend/src/styles/fonts.css:1-70`. These fonts are not bundled by the Apple client;
/// ``WebIconFontLoader`` resolves these same root-relative paths against the configured game
/// server at runtime.
enum WebIconFontFamily: String, CaseIterable, Sendable, Hashable, Codable {
    case arkham = "Arkham"
    case arkhamIcons = "ArkhamIcons"
    case arkhamSlim = "ArkhamSlim"
    case icons = "Icons"

    /// Internal PostScript names from the real font files at fork commit
    /// 4203738708b0ad2d3cff426b4ce2e6b3d9904fec (`frontend/public/fonts`).
    var expectedPostScriptName: String {
        switch self {
        case .arkham: "AHLCG"
        case .arkhamIcons: "arkhamicons"
        case .arkhamSlim: "arkhamslim"
        case .icons: "icon"
        }
    }
}

struct WebIconFontSource: Sendable, Equatable, Hashable {
    let family: WebIconFontFamily
    /// Root-relative path served by the web origin's static font route.
    let path: String
}

enum WebIconFontSources {
    /// Font list mirrored from fork commit 4203738708b0ad2d3cff426b4ce2e6b3d9904fec:
    /// - `frontend/src/styles/fonts.css:1-3` (`Arkham` -> `/fonts/arkham.ttf`)
    /// - `frontend/src/styles/fonts.css:53-55` (`ArkhamIcons` -> `/fonts/arkhamicons.ttf`)
    /// - `frontend/src/styles/fonts.css:58-60` (`Icons` -> `/fonts/icon.woff2`)
    /// - `frontend/src/styles/fonts.css:68-70` (`ArkhamSlim` -> `/fonts/arkhamslim.ttf`)
    static let required: [WebIconFontSource] = [
        WebIconFontSource(family: .arkham, path: "/fonts/arkham.ttf"),
        WebIconFontSource(family: .arkhamIcons, path: "/fonts/arkhamicons.ttf"),
        WebIconFontSource(family: .icons, path: "/fonts/icon.woff2"),
        WebIconFontSource(family: .arkhamSlim, path: "/fonts/arkhamslim.ttf"),
    ]
}

struct WebIconFontRegistration: Sendable, Equatable {
    let family: WebIconFontFamily
    /// The actual CoreText/PostScript font name. This intentionally is not the CSS name:
    /// the web font files use internal names such as `AHLCG`, `arkhamicons`, and `icon`.
    let postScriptName: String
    let supportedScalars: Set<UInt32>

    func supports(_ glyph: StoryIconGlyph) -> Bool {
        glyph.family == family && supportedScalars.contains(glyph.scalar.value)
    }
}

struct WebIconFontAvailability: Sendable, Equatable {
    var registrations: [WebIconFontFamily: WebIconFontRegistration]

    init(registrations: [WebIconFontFamily: WebIconFontRegistration] = [:]) {
        self.registrations = registrations
    }

    var loadedFamilies: Set<WebIconFontFamily> {
        Set(registrations.keys)
    }

    func postScriptName(for glyph: StoryIconGlyph) -> String? {
        guard let registration = registrations[glyph.family], registration.supports(glyph) else {
            return nil
        }
        return registration.postScriptName
    }
}

/// One semantic story icon's exact web glyph mapping.
struct StoryIconGlyph: Sendable, Equatable, Hashable {
    let iconName: String
    let cssClass: String
    let family: WebIconFontFamily
    let scalar: UnicodeScalar

    var string: String {
        String(scalar)
    }
}

extension StoryIconGlyph {
    /// Web mapping mirrored exactly from fork commit
    /// 4203738708b0ad2d3cff426b4ce2e6b3d9904fec,
    /// `frontend/src/styles/icons.css`:
    /// - chaos: elder sign/auto fail (`:49-65`), skull/cultist/tablet/elder thing
    ///   (`:111-139`), curse/bless (`:143-155`), frost (`:159-163`), blood (`:167-171`)
    /// - skills: willpower/intellect/combat/agility (`:78-107`), wild (`:240-244`)
    /// - seals: seal A-E (`:176-212`)
    static let storyGlyphs: [StoryIconGlyph] = [
        glyph("skull", "skull-icon", .arkhamIcons, "\u{E910}"),
        glyph("cultist", "cultist-icon", .arkhamIcons, "\u{E911}"),
        glyph("tablet", "tablet-icon", .arkhamIcons, "\u{E912}"),
        glyph("elderThing", "elder-thing-icon", .arkhamIcons, "\u{E913}"),
        glyph("autoFail", "auto-fail", .arkham, "\u{005A}"),
        glyph("elderSign", "elder-sign", .arkham, "\u{0058}"),
        glyph("curse", "curse-icon", .arkhamIcons, "\u{E929}"),
        glyph("bless", "bless-icon", .arkhamIcons, "\u{E92A}"),
        glyph("frost", "frost-icon", .arkhamSlim, "\u{0062}"),
        glyph("blood", "blood-icon", .icons, "\u{E94A}"),
        glyph("willpower", "willpower-icon", .arkham, "\u{0041}"),
        glyph("intellect", "intellect-icon", .arkham, "\u{0046}"),
        glyph("combat", "combat-icon", .arkham, "\u{0044}"),
        glyph("agility", "agility-icon", .arkham, "\u{0053}"),
        glyph("wild", "wild-icon", .arkham, "\u{0047}"),
        glyph("sealA", "seal-a-icon", .arkhamSlim, "\u{0067}"),
        glyph("sealB", "seal-b-icon", .arkhamSlim, "\u{0066}"),
        glyph("sealC", "seal-c-icon", .arkhamSlim, "\u{0065}"),
        glyph("sealD", "seal-d-icon", .arkhamSlim, "\u{0063}"),
        glyph("sealE", "seal-e-icon", .arkhamSlim, "\u{0064}"),
    ]

    /// Additional log glyphs from `frontend/src/styles/icons.css:9-47,69-76,248-274,283-490`.
    static let logGlyphs: [StoryIconGlyph] = [
        glyph("action", "action-icon", .arkham, "\u{0049}"),
        glyph("fast", "fast-icon", .arkham, "\u{0075}"),
        glyph("reaction", "reaction-icon", .arkham, "\u{0079}"),
        glyph("guardian", "guardian-icon", .arkham, "\u{0051}"),
        glyph("seeker", "seeker-icon", .arkham, "\u{0045}"),
        glyph("rogue", "rogue-icon", .arkham, "\u{0054}"),
        glyph("mystic", "mystic-icon", .arkham, "\u{0057}"),
        glyph("survivor", "survivor-icon", .arkham, "\u{0052}"),
    ] + (0 ..< 26).compactMap { offset in
        guard let letter = UnicodeScalar(65 + offset),
              let scalar = UnicodeScalar(0xE900 + offset) else { return nil }
        let name = "rune-\(letter)"
        return StoryIconGlyph(iconName: name, cssClass: name, family: .arkhamSlim, scalar: scalar)
    }

    static let all = storyGlyphs + logGlyphs

    private static func glyph(
        _ iconName: String,
        _ cssClass: String,
        _ family: WebIconFontFamily,
        _ scalar: UnicodeScalar
    ) -> StoryIconGlyph {
        StoryIconGlyph(
            iconName: iconName,
            cssClass: cssClass,
            family: family,
            scalar: scalar
        )
    }

    static let byIconName: [String: StoryIconGlyph] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.iconName, $0) }
    )
}

extension StoryIcon {
    var iconName: String {
        switch self {
        case let .chaosToken(face): face.catalogIconName
        case let .skill(skill): skill.rawValue
        case let .seal(seal): seal.rawValue
        }
    }

    var webGlyph: StoryIconGlyph? {
        StoryIconGlyph.byIconName[iconName]
    }
}
