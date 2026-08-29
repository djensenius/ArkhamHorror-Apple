/// The named chaos token art variants the web client ships.
///
/// Mirrors `tokenImageNames` in `frontend/src/arkham/types/ChaosToken.ts`
/// exactly: each case maps to `chaos-tokens/ct-<name>.png`.
enum ChaosTokenFace: String, CaseIterable, Sendable, Equatable, Hashable {
    case plusOne = "plus1"
    case zero = "0"
    case minusOne = "minus1"
    case minusTwo = "minus2"
    case minusThree = "minus3"
    case minusFour = "minus4"
    case minusFive = "minus5"
    case minusSix = "minus6"
    case minusSeven = "minus7"
    case minusEight = "minus8"
    case skull
    case cultist
    case tablet
    case elderThing = "elderthing"
    case autoFail = "autofail"
    case elderSign = "eldersign"
    case curse
    case bless
    case frost
    case blood
    /// The generic placeholder art for an unrecognised/unresolved face.
    case blank
}

/// A small, fixed slot-icon vocabulary used outside card art (resource,
/// clue, and lead-investigator markers). Mirrors the literal `tokens/*.png`
/// paths referenced across the web client's Vue components.
enum SlotIcon: String, CaseIterable, Sendable, Equatable, Hashable {
    case clue
    case resource
    case leadInvestigator = "lead-investigator"
}

/// The specific side/variant of a card an ``AssetKey`` requests art for.
///
/// This intentionally does not attempt to replicate the web client's
/// card-type-conditional back/front selection rules (which require a full
/// `CardDef` game model this feature does not depend on). Callers that own
/// that domain knowledge construct the specific ``AssetIdentifier`` for the
/// side they want to show; this type only distinguishes the two path
/// families the CDN actually serves for a card.
enum CardArtRole: Sendable, Equatable, Hashable {
    /// Card-specific art at `cards/<identifier>.avif` (or the homebrew
    /// equivalent). Used uniformly for fronts, double-sided backs with their
    /// own art, resolved act/agenda backs, and mutated asset/event art —
    /// every one of these is just a different ``AssetIdentifier`` value.
    case art
    /// A generic (non-card-specific) card back: the shared encounter back,
    /// shared player back, or a scenario's custom back image.
    case genericBack(GenericBack)
}

/// The three generic card backs the web client falls back to when a card has
/// no distinct back art of its own (`ENCOUNTER_BACK` / `PLAYER_BACK` /
/// `card.meta.customBack` in `frontend/src/arkham/cardArt.ts`).
enum GenericBack: Sendable, Equatable, Hashable {
    case encounter
    case player
    /// A scenario-specific custom back, e.g. `"back_artifact"` in
    /// `.jpeg`, or a story card's own-named back such as
    /// `"children_of_blood"` in `.avif`. The backend's `customBack` meta
    /// value supplies both the base name and its extension, so both are
    /// carried explicitly rather than assumed from the category.
    case custom(AssetIdentifier, format: AssetFormat)
}

/// The category of asset an ``AssetKey`` requests, and whether it is an
/// official CDN asset or lives under a homebrew campaign's directory.
///
/// Every case carries only the strongly-typed identifiers that category's
/// path grammar needs; there is no case that accepts an arbitrary path or
/// URL string.
enum AssetCategory: Sendable, Equatable, Hashable {
    /// `cards/<identifier>.avif` or `backs/<back>.jpg`.
    case card(CardArtRole, AssetIdentifier)
    /// `homebrew/<campaign>/cards/<identifier>.avif`. Homebrew card art has
    /// no generic-back path on the CDN; a homebrew card with no back art
    /// simply has no back candidate.
    case homebrewCard(campaign: AssetIdentifier, art: AssetIdentifier)
    /// `portraits/<identifier>.jpg`.
    case portrait(AssetIdentifier)
    /// `chaos-tokens/ct-<face>.png`.
    case chaosToken(ChaosTokenFace)
    /// `homebrew/<campaign>/chaos-tokens/<key>.png`.
    case homebrewChaosToken(campaign: AssetIdentifier, key: AssetIdentifier)
    /// `sets/<identifier>.png`, or `sets/<identifier>-<variant>.png` when a
    /// variant (e.g. a side-story suffix) is supplied.
    case setIcon(AssetIdentifier, variant: AssetIdentifier?)
    /// `homebrew/<campaign>/sets/<identifier>.png`.
    case homebrewSetIcon(campaign: AssetIdentifier, identifier: AssetIdentifier)
    /// `boxes/<identifier>.jpg`.
    case campaignBox(AssetIdentifier)
    /// `homebrew/<campaign>/boxes/<campaign>.jpg` — the web client always
    /// reuses the campaign slug itself as the box art identifier.
    case homebrewCampaignBox(campaign: AssetIdentifier)
    /// `tokens/<slot>.png`.
    case slotIcon(SlotIcon)
}

extension AssetCategory {
    /// The image format the CDN serves for this category, independent of
    /// locale or which candidate in the fallback chain resolves.
    var expectedFormat: AssetFormat {
        switch self {
        case .card(.art, _), .homebrewCard:
            .avif
        case let .card(.genericBack(back), _):
            switch back {
            case .encounter, .player: .jpeg
            case let .custom(_, format): format
            }
        case .portrait, .campaignBox, .homebrewCampaignBox:
            .jpeg
        case .chaosToken, .homebrewChaosToken, .setIcon, .homebrewSetIcon, .slotIcon:
            .png
        }
    }

    /// Whether this category's path is looked up against the localized
    /// digest before falling back to English. Only the shared `cards/`
    /// path family is localized on the CDN; every other category (generic
    /// backs, portraits, chaos tokens, set icons, boxes, homebrew, slot
    /// icons) is English-only regardless of the requested locale.
    var isLocalizable: Bool {
        if case .card(.art, _) = self {
            return true
        }
        return false
    }
}
