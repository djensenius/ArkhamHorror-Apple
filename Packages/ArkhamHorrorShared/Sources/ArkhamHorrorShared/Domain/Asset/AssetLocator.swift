/// Pure, deterministic resolution of an ``AssetKey`` into an ordered
/// candidate fallback chain.
///
/// No I/O happens here. Given the same key and the same digest lookup
/// answers, the candidate list is always identical and in the same order —
/// this is what lets ``AssetCacheService`` fold the whole candidate sequence
/// into a stable disk cache key and lets tests assert exact URLs.
///
/// Candidates only ever advance on a definitive 404 (never on timeouts, TLS
/// errors, 5xx, cancellation, or invalid content); that policy lives in
/// ``AssetCacheService``, which is the only thing that walks this list
/// against the network.
enum AssetLocator {
    /// Returns the ordered, deduplicated candidate list for `key`.
    ///
    /// - For localizable categories (currently only card art): the
    ///   candidate order is `[localized?, english, alternateFront?]`. The
    ///   localized candidate is included only when `key.locale` has a
    ///   non-English path root and `digest` reports a localized entry for
    ///   the requested identifier; the alternate-front candidate is
    ///   included only for a bare numeric card code (no side/mutation
    ///   suffix already present).
    /// - Every other category resolves to exactly one candidate.
    static func candidates(
        for key: AssetKey,
        digest: any LocalizedDigestLookup = BundledLocalizedDigestProvider.shared
    ) -> [AssetCandidate] {
        switch key.category {
        case let .card(.art, identifier):
            cardArtCandidates(
                identifier: identifier,
                locale: key.locale,
                digest: digest,
                homebrew: nil
            )

        case let .homebrewCard(campaign, art):
            cardArtCandidates(
                identifier: art,
                locale: .english,
                digest: digest,
                homebrew: campaign
            )

        case let .card(.genericBack(back), _):
            [genericBackCandidate(back)]

        default:
            [singleCandidate(for: key.category)]
        }
    }

    /// Builds the single candidate for every category that never
    /// participates in localization or the front/back fallback chain
    /// (i.e. every ``AssetCategory`` case besides `.card` and
    /// `.homebrewCard`, which ``candidates(for:digest:)`` always handles
    /// itself before reaching here).
    private static func singleCandidate(for category: AssetCategory) -> AssetCandidate {
        let (segments, format) = pathComponents(for: category)
        return AssetCandidateFactory.make(segments: segments, localeRoot: nil, format: format)
    }

    /// The path segments and format for every non-card ``AssetCategory``.
    private static func pathComponents(
        for category: AssetCategory
    ) -> (segments: [String], format: AssetFormat) {
        switch category {
        case let .portrait(identifier):
            return (
                ["portraits", "\(identifier.rawValue).\(AssetFormat.jpeg.pathExtension)"],
                .jpeg
            )
        case let .chaosToken(face):
            return (["chaos-tokens", "ct-\(face.rawValue).png"], .png)
        case let .homebrewChaosToken(campaign, key: tokenKey):
            return (
                ["homebrew", campaign.rawValue, "chaos-tokens", "\(tokenKey.rawValue).png"],
                .png
            )
        case let .setIcon(identifier, variant):
            let suffix = variant.map { "-\($0.rawValue)" } ?? ""
            return (["sets", "\(identifier.rawValue)\(suffix).png"], .png)
        case let .homebrewSetIcon(campaign, identifier):
            return (["homebrew", campaign.rawValue, "sets", "\(identifier.rawValue).png"], .png)
        case let .campaignBox(identifier):
            return (["boxes", "\(identifier.rawValue).jpg"], .jpeg)
        case let .homebrewCampaignBox(campaign):
            return (["homebrew", campaign.rawValue, "boxes", "\(campaign.rawValue).jpg"], .jpeg)
        case let .slotIcon(icon):
            return (["tokens", "\(icon.rawValue).png"], .png)
        case .card, .homebrewCard:
            preconditionFailure(
                "card/homebrewCard are always handled by candidates(for:digest:) directly"
            )
        }
    }

    /// The back-side art identifier for an act or agenda that has advanced
    /// past a given front side, matching `resolvedSideArt` in
    /// `frontend/src/arkham/cardImages.ts` exactly (including its pinned
    /// disambiguation overrides).
    ///
    /// `front` must be a bare card code ending in one of the front-side
    /// letters `a`, `c`, `e`, or `g` (every printed back shares the same
    /// `…b` art, including four-sided acts where side `d` reuses side `b`'s
    /// image).
    static func resolvedBackIdentifier(from front: AssetIdentifier) -> AssetIdentifier {
        let raw = front.rawValue
        if let override = resolvedSideOverrides[raw] {
            if let identifier = try? AssetIdentifier.cardCode(override) {
                return identifier
            }
        }
        guard let last = raw.last, "aceg".contains(last) else {
            // Not a documented front-side identifier (e.g. already a back,
            // or some other mutation suffix): the generic strip-and-append
            // rule does not apply here. Fail closed by returning the input
            // unchanged rather than risking a double-mutated identifier
            // like an errant "...bb".
            return front
        }
        var base = raw
        base.removeLast()
        let candidate = base + "b"
        guard let identifier = try? AssetIdentifier.cardCode(candidate) else {
            // The input was already validated on construction, so appending a
            // single trailing "b" can only fail the grammar if the caller
            // supplied an identifier this function was never meant to be
            // called with (e.g. one that already carries a mutation suffix).
            // Fail safe by returning the original, unmodified identifier
            // rather than producing an unvalidated value.
            return front
        }
        return identifier
    }

    /// A handful of acts and agendas end their id in a letter that
    /// disambiguates two printings rather than naming a side, so the
    /// generic strip-the-side rule would resolve them onto a different
    /// card's front. Pinned verbatim from `RESOLVED_SIDE_OVERRIDES` in
    /// `frontend/src/arkham/cardImages.ts`.
    private static let resolvedSideOverrides: [String: String] = [
        "03276a": "03276ab",
        "03276b": "03276bb",
        "03279a": "03279ab",
        "03279b": "03279bb",
    ]

    private static func genericBackCandidate(_ back: GenericBack) -> AssetCandidate {
        switch back {
        case .encounter:
            AssetCandidateFactory.make(
                segments: ["backs", "back_encounter.jpg"],
                localeRoot: nil,
                format: .jpeg
            )
        case .player:
            AssetCandidateFactory.make(
                segments: ["backs", "back_player.jpg"],
                localeRoot: nil,
                format: .jpeg
            )
        case let .custom(identifier, format):
            AssetCandidateFactory.make(
                segments: ["backs", "\(identifier.rawValue).\(format.pathExtension)"],
                localeRoot: nil,
                format: format
            )
        }
    }

    /// Shared ordering for the two card-art request shapes (official and
    /// homebrew). Homebrew art is never localized: the digest is keyed by
    /// the bare `cards/<code>.avif` path, which a homebrew path never
    /// matches, so `locale` is forced to `.english` by both call sites
    /// above before reaching here — this function only handles the
    /// official localization branch when `homebrew` is `nil`.
    private static func cardArtCandidates(
        identifier: AssetIdentifier,
        locale: AssetLocale,
        digest: any LocalizedDigestLookup,
        homebrew campaign: AssetIdentifier?
    ) -> [AssetCandidate] {
        let ext = AssetFormat.avif.pathExtension
        func segments(for id: AssetIdentifier) -> [String] {
            if let campaign {
                ["homebrew", campaign.rawValue, "cards", "\(id.rawValue).\(ext)"]
            } else {
                ["cards", "\(id.rawValue).\(ext)"]
            }
        }

        var ordered: [AssetCandidate] = []
        if campaign == nil, let root = locale.pathRoot, digest.hasLocalizedArt(
            identifier,
            locale: locale
        ) {
            ordered.append(AssetCandidateFactory.make(
                segments: segments(for: identifier),
                localeRoot: root,
                format: .avif
            ))
        }
        ordered.append(AssetCandidateFactory.make(
            segments: segments(for: identifier),
            localeRoot: nil,
            format: .avif
        ))

        if let alternate = alternateFrontIdentifier(identifier) {
            ordered.append(AssetCandidateFactory.make(
                segments: segments(for: alternate),
                localeRoot: nil,
                format: .avif
            ))
        }
        return ordered
    }

    /// The alternate-front identifier for a bare numeric card code (e.g.
    /// `"13093"` → `"13093a"`), matching `altFrontImage` in
    /// `frontend/src/arkham/cardArt.ts`. Returns `nil` for any code that
    /// already carries a side letter, an `x`-prefixed special form, or a
    /// mutation suffix, since appending another letter to those would not
    /// reproduce the web client's narrow retry.
    private static func alternateFrontIdentifier(
        _ identifier: AssetIdentifier
    ) -> AssetIdentifier? {
        let raw = identifier.rawValue
        guard raw.allSatisfy(\.isNumber), (2 ... 6).contains(raw.count) else { return nil }
        return try? AssetIdentifier.cardCode(raw + "a")
    }
}
