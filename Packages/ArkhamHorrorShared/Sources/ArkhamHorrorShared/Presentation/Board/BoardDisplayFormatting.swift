import Foundation

/// Pure, side-effect-free display-string formatting shared by ``BoardProjectionBuilder``
/// and the SwiftUI board views' accessibility labels/values. Every function here is purely
/// cosmetic: none interprets a wire tag's actual rules effect, and every closed
/// ``unknown(tag:rawObject:)`` case renders a fixed, human-readable "requires a future
/// update" sentence rather than the tag or raw JSON, per this slice's boundary on
/// unsupported/deferred content.
enum BoardDisplayFormatting {
    /// The fixed sentence shown for any wire shape this client build does not recognize.
    /// Never includes the raw tag or JSON payload: those are wire implementation details,
    /// not user-facing content.
    static let unsupportedContentNotice = "Not supported by this app version yet"

    /// A safe display title: `name.title` if non-blank, else `fallback` (typically a raw
    /// card code or identifier), so a blank or whitespace-only wire title never produces an
    /// empty accessibility label or heading.
    static func safeTitle(_ name: CardName, fallback: String) -> String {
        let trimmed = name.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// A safe display label for a bare wire `String` field (for example `Location.label`).
    static func safeLabel(_ label: String, fallback: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// `name.subtitle`, trimmed to `nil` if blank (rather than showing an empty subtitle).
    static func safeSubtitle(_ name: CardName) -> String? {
        guard let subtitle = name.subtitle else { return nil }
        let trimmed = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A display-only summary of a `GameValue` (for example a shroud or doom threshold),
    /// never resolving what the value actually evaluates to at runtime.
    static func gameValueSummary(_ value: GameValue) -> String {
        switch value {
        case let .staticValue(amount):
            "\(amount)"
        case let .perPlayer(amount):
            "\(amount) per investigator"
        case let .staticWithPerPlayer(base, perPlayer):
            "\(base) + \(perPlayer) per investigator"
        case let .byPlayerCount(one, two, three, four):
            "\(one)/\(two)/\(three)/\(four) by player count"
        case .valueX:
            "X"
        case .valueStar:
            "★"
        case .valueUnknown:
            "Unknown"
        case .unknown:
            unsupportedContentNotice
        }
    }

    /// A display-only summary of a `RuntimeCost` (`Act.advanceCost`,
    /// `Location.costToEnterUnrevealed`), showing only its closed wire tag humanized —
    /// never interpreting `contents`, which stays a broad, unconstrained payload.
    static func runtimeCostSummary(_ cost: RuntimeCost) -> String {
        humanizeTag(cost.tag)
    }

    /// A display-only summary of `Investigator.movement`'s means and destination, never
    /// resolving a `LocationMatcher` or reading `moveSource`/`moveTarget`.
    static func movementSummary(_ movement: Movement) -> String {
        let meansText: String = switch movement.moveMeans {
        case .direct: "moving directly"
        case .oneAtATime: "moving one step at a time"
        case .towards: "moving towards a destination"
        case .place: "being placed"
        case let .towardsN(steps): "moving \(steps) step(s)"
        case .unknown: unsupportedContentNotice
        }
        switch movement.moveDestination {
        case .toLocation:
            return "\(meansText) to a specific location"
        case .toLocationMatching:
            return "\(meansText) to a matching location"
        case .unknown:
            return unsupportedContentNotice
        }
    }

    /// A display-only summary of `PublicGame.phaseStep`'s sub-step, or `nil` when no step
    /// is active.
    static func phaseStepSummary(_ step: PhaseStep?) -> String? {
        guard let step else { return nil }
        switch step {
        case let .mythos(substep): return humanizeTag(substep.rawValue)
        case let .investigation(substep): return humanizeTag(substep.rawValue)
        case let .enemy(substep): return humanizeTag(substep.rawValue)
        case let .upkeep(substep): return humanizeTag(substep.rawValue)
        case .unknown: return unsupportedContentNotice
        }
    }

    /// A display-only summary of `PublicGame.gameState`.
    static func gameStateSummary(_ state: GameState) -> String {
        switch state {
        case let .pending(players):
            "Waiting for \(pluralized(players.count, singular: "player", plural: "players")) " +
                "to join"
        case let .chooseDecks(players):
            "Waiting for \(pluralized(players.count, singular: "player", plural: "players")) " +
                "to choose a deck"
        case .active: "Active"
        case .over: "Over"
        case .unknown: unsupportedContentNotice
        }
    }

    /// A natural-language count-plus-noun phrase (for example "1 player"/"2 players"),
    /// never a "(s)" placeholder — both for on-screen text and for VoiceOver, which reads
    /// a literal "(s)" suffix awkwardly aloud.
    static func pluralized(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    /// A display-only summary of a `Placement`, showing only its closed wire tag
    /// humanized — never interpreting `contents`.
    static func placementSummary(_ placement: Placement) -> String {
        humanizeTag(placement.kind.rawValue)
    }

    /// Groups a token multiset into deterministic, plain-`String`-sorted (never
    /// locale-sensitive) counts, merging any duplicate token names the wire array might
    /// repeat.
    static func groupTokenCounts(_ tokens: [TokenCount]) -> [BoardTokenSummary] {
        var totals: [String: Int] = [:]
        for token in tokens {
            totals[token.token, default: 0] += token.count
        }
        return totals
            .map { BoardTokenSummary(token: $0.key, count: $0.value) }
            .sorted { $0.token < $1.token }
    }

    /// The canonical base-game chaos-token face order, used so common faces always sort
    /// first in a fixed, human-familiar order; any additive/homebrew face this client
    /// build does not list here sorts afterward, alphabetically by raw text.
    private static let canonicalFaceOrder: [ChaosTokenFace] = [
        .plusOne, .zero, .minusOne, .minusTwo, .minusThree, .minusFour, .minusFive, .minusSix,
        .minusSeven, .minusEight, .skull, .cultist, .tablet, .elderThing, .autoFail, .elderSign,
        .curseToken, .blessToken, .frostToken, .bloodToken,
    ]

    /// Groups a chaos-token multiset into deterministic, canonical-then-alphabetical
    /// counts.
    static func groupChaosFaceCounts(_ tokens: [ChaosToken]) -> [BoardChaosFaceCount] {
        var totals: [ChaosTokenFace: Int] = [:]
        for token in tokens {
            totals[token.chaosTokenFace, default: 0] += 1
        }
        return totals
            .map { BoardChaosFaceCount(face: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                let lhsIndex = canonicalFaceOrder.firstIndex(of: lhs.face)
                let rhsIndex = canonicalFaceOrder.firstIndex(of: rhs.face)
                switch (lhsIndex, rhsIndex) {
                case let (.some(left), .some(right)):
                    return left < right
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return lhs.face.rawValue < rhs.face.rawValue
                }
            }
    }

    /// Turns a wire `PascalCase`/`camelCase`-ish tag (for example `"HunterEnemiesMoveStep"`
    /// or `"GroupClueCost"`) into a space-separated display string ("Hunter Enemies Move
    /// Step"), stripping a trailing `Step`/`Cost`/`Window` word if present is deliberately
    /// **not** done here: the raw humanized tag is left intact so this stays a purely
    /// mechanical, lossless transform with no risk of misrepresenting an unfamiliar tag.
    static func humanizeTag(_ tag: String) -> String {
        var words: [String] = []
        var current = ""
        for scalar in tag.unicodeScalars {
            if CharacterSet.uppercaseLetters.contains(scalar), !current.isEmpty {
                words.append(current)
                current = String(scalar)
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty {
            words.append(current)
        }
        return words.isEmpty ? tag : words.joined(separator: " ")
    }
}
