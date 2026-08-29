import Foundation

/// A `CardCode`-backed identifier distinguished at compile time by a phantom `Tag`, mirroring
/// ``Identifier`` (which wraps `UUID`) for the backend's `CardCode`-backed newtypes (for
/// example `InvestigatorId`/`ActId`/`AgendaId`, `Arkham/Id.hs`). Decoding delegates to
/// ``CardCode``'s own validating `Decodable` conformance, never force-unwrapping or
/// re-deriving its `^c.+$` validation here.
struct CardCodeIdentifier<Tag: Sendable>: Sendable {
    let rawValue: CardCode

    init(_ rawValue: CardCode) {
        self.rawValue = rawValue
    }
}

extension CardCodeIdentifier: Equatable, Hashable {}

extension CardCodeIdentifier: Codable {
    init(from decoder: any Decoder) throws {
        rawValue = try CardCode(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        try rawValue.encode(to: encoder)
    }
}

extension CardCodeIdentifier: CustomStringConvertible {
    var description: String {
        rawValue.description
    }
}

// MARK: - `Dictionary` map-key support

//
// Conforming `Identifier`/`CardCodeIdentifier`/`CardCode` to `CodingKeyRepresentable` (a
// stdlib protocol since Swift 5.6) lets the standard library's own conditional
// `Dictionary: Codable` conformance decode/encode `[Identifier<Tag>: Value]` and
// `[CardCode: Value]` as ordinary JSON objects (matching the wire's `uuidMapKey`/
// `cardCodeMapKey` property-name domains) through `container(keyedBy:)` — which
// ``LosslessJSONValueDecoder``/``LosslessJSONValueEncoder`` already implement generically
// for any `CodingKey` type, not only fixed enum keys — rather than falling back to the
// stdlib's alternate "flat array of alternating key/value pairs" encoding it uses for
// non-`CodingKeyRepresentable` keys, which would not match the backend's actual object
// shape at all.

extension Identifier: CodingKeyRepresentable {
    var codingKey: CodingKey {
        AnyCodingKey(stringValue: rawValue.uuidString)
    }

    init?(codingKey: some CodingKey) {
        guard let uuid = UUID(uuidString: codingKey.stringValue) else { return nil }
        self.init(uuid)
    }
}

extension CardCodeIdentifier: CodingKeyRepresentable {
    var codingKey: CodingKey {
        AnyCodingKey(stringValue: rawValue.rawValue)
    }

    init?(codingKey: some CodingKey) {
        guard let code = try? CardCode(codingKey.stringValue) else { return nil }
        self.init(code)
    }
}

extension CardCode: CodingKeyRepresentable {
    var codingKey: CodingKey {
        AnyCodingKey(stringValue: rawValue)
    }

    init?(codingKey: some CodingKey) {
        try? self.init(codingKey.stringValue)
    }
}

// MARK: - Board entity identity domains

//
// Every map in `PublicGame` keyed by a UUID- or `CardCode`-backed newtype gets its own
// phantom tag here, even though this slice leaves every map's *value* shape an
// intentionally broad ``JSONValue`` placeholder (see `public-game.schema.json`'s
// `uuidEntityMap`/`cardCodeEntityMap` `$defs`): a stable, distinctly-typed key per entity
// domain is exactly what a future snapshot diff/focus feature needs, so an `EnemyID`
// can never be interchanged with an `AssetID` or a `LocationID` even before this slice
// models what either entity actually contains.

/// Phantom tag distinguishing ``LocationID``.
enum LocationIDTag: Sendable {}
/// A location's `LocationId` (UUID), `Arkham/Id.hs`.
typealias LocationID = Identifier<LocationIDTag>

/// Phantom tag distinguishing ``EnemyID``.
enum EnemyIDTag: Sendable {}
/// An enemy's `EnemyId` (UUID), `Arkham/Id.hs`.
typealias EnemyID = Identifier<EnemyIDTag>

/// Phantom tag distinguishing ``AssetID``.
enum AssetIDTag: Sendable {}
/// An asset's `AssetId` (UUID), `Arkham/Id.hs`.
typealias AssetID = Identifier<AssetIDTag>

/// Phantom tag distinguishing ``TreacheryID``.
enum TreacheryIDTag: Sendable {}
/// A treachery's `TreacheryId` (UUID), `Arkham/Id.hs`.
typealias TreacheryID = Identifier<TreacheryIDTag>

/// Phantom tag distinguishing ``EventID``.
enum EventIDTag: Sendable {}
/// An event's `EventId` (UUID), `Arkham/Id.hs`.
typealias EventID = Identifier<EventIDTag>

/// Phantom tag distinguishing ``SkillID``.
enum SkillIDTag: Sendable {}
/// A skill-test-in-progress `SkillId` (UUID), `Arkham/Id.hs`.
typealias SkillID = Identifier<SkillIDTag>

/// Phantom tag distinguishing ``ConcealedCardID``.
enum ConcealedCardIDTag: Sendable {}
/// A concealed card's `ConcealedCardId` (UUID), `Arkham/Id.hs`.
typealias ConcealedCardID = Identifier<ConcealedCardIDTag>

/// Phantom tag distinguishing ``WireCardID``.
enum WireCardIDTag: Sendable {}
/// A physical card instance's `CardId` (UUID), `Arkham/Card/Id.hs`. Shared by
/// `PublicGame.cards`' map key and every entity's own `cardId` field.
typealias WireCardID = Identifier<WireCardIDTag>

/// Phantom tag distinguishing ``MovementID``.
enum MovementIDTag: Sendable {}
/// An in-progress move's `MovementId` (UUID), `Arkham/Id.hs`.
typealias MovementID = Identifier<MovementIDTag>

/// Phantom tag distinguishing ``ChaosTokenID``.
enum ChaosTokenIDTag: Sendable {}
/// A physical chaos token instance's id (UUID), `Arkham.ChaosToken.Types.ChaosToken`.
typealias ChaosTokenID = Identifier<ChaosTokenIDTag>

/// Phantom tag distinguishing ``InvestigatorID``.
enum InvestigatorIDTag: Sendable {}
/// An investigator's `InvestigatorId` (`CardCode`-backed), `Arkham/Id.hs`.
typealias InvestigatorID = CardCodeIdentifier<InvestigatorIDTag>

/// Phantom tag distinguishing ``ActID``.
enum ActIDTag: Sendable {}
/// An act's `ActId` (`CardCode`-backed), `Arkham/Id.hs`.
typealias ActID = CardCodeIdentifier<ActIDTag>

/// Phantom tag distinguishing ``AgendaID``.
enum AgendaIDTag: Sendable {}
/// An agenda's `AgendaId` (`CardCode`-backed), `Arkham/Id.hs`.
typealias AgendaID = CardCodeIdentifier<AgendaIDTag>
