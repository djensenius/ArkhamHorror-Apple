import Foundation

/// Safe, display-only parsers for the public snapshot's broad entity maps. The governed
/// schema intentionally leaves these values as opaque objects, so every field here is
/// optional and fail-closed: typed placement arrays decide whether an entity is visible,
/// while malformed broad values merely fall back to ID/code text.
extension BoardProjectionBuilder {
    // MARK: - Player cards / threat area

    static func makeInPlayCards(
        from snapshot: PublicGameSnapshot
    ) -> [PlayerID: [BoardPlayerCardNode]] {
        var result: [PlayerID: [BoardPlayerCardNode]] = [:]
        for investigator in orderedInvestigatorsForPlayerAreas(in: snapshot) {
            var nodes: [BoardPlayerCardNode] = []
            nodes.append(contentsOf: investigator.assets.map {
                inPlayCardNode(
                    id: .asset($0), cardID: rawCardID(in: snapshot.assets[$0]),
                    rawValue: snapshot.assets[$0], zone: .asset, ownerID: investigator.playerID
                )
            })
            nodes.append(contentsOf: investigator.events.map {
                inPlayCardNode(
                    id: .event($0), cardID: rawCardID(in: snapshot.events[$0]),
                    rawValue: snapshot.events[$0], zone: .event, ownerID: investigator.playerID
                )
            })
            nodes.append(contentsOf: investigator.skills.map {
                inPlayCardNode(
                    id: .skill($0), cardID: rawCardID(in: snapshot.skills[$0]),
                    rawValue: snapshot.skills[$0], zone: .skill, ownerID: investigator.playerID
                )
            })
            result[investigator.playerID] = nodes
        }
        return result
    }

    static func makeThreatTreacheries(
        from snapshot: PublicGameSnapshot
    ) -> [PlayerID: [BoardThreatTreacheryNode]] {
        var result: [PlayerID: [BoardThreatTreacheryNode]] = [:]
        for investigator in orderedInvestigatorsForPlayerAreas(in: snapshot) {
            result[investigator.playerID] = investigator.treacheries.map {
                threatTreacheryNode(
                    id: $0,
                    rawValue: snapshot.treacheries[$0],
                    ownerID: investigator.playerID
                )
            }
        }
        return result
    }

    // MARK: - Enemies

    static func makeEnemyPlacement(
        from snapshot: PublicGameSnapshot,
        locations: [BoardLocationNode],
        enemyLocations: [BoardEnemyLocationNode]
    ) -> (
        byLocationID: [LocationID: [BoardEnemyNode]],
        engagedByInvestigatorID: [InvestigatorID: [BoardEnemyNode]]
    ) {
        let engagedEnemyIDs = Set(snapshot.investigators.values.flatMap(\.engagedEnemies))
        var byLocationID: [LocationID: [BoardEnemyNode]] = [:]
        for location in locations {
            let enemies = enemyIDs(at: location.id, in: snapshot)
                .filter { !engagedEnemyIDs.contains($0) }
                .map {
                    enemyNode(
                        id: $0, rawValue: snapshot.enemies[$0],
                        playerCount: snapshot.playerCount, locationID: location.id
                    )
                }
            if !enemies.isEmpty {
                byLocationID[location.id] = enemies
            }
        }
        for location in enemyLocations {
            let enemies = enemyIDs(at: location.id, in: snapshot)
                .filter { !engagedEnemyIDs.contains($0) }
                .map {
                    enemyNode(
                        id: $0, rawValue: snapshot.enemies[$0],
                        playerCount: snapshot.playerCount, locationID: location.id
                    )
                }
            if !enemies.isEmpty {
                byLocationID[location.id] = enemies
            }
        }

        var engagedByInvestigatorID: [InvestigatorID: [BoardEnemyNode]] = [:]
        for investigator in orderedInvestigatorsForPlayerAreas(in: snapshot) {
            let enemies = investigator.engagedEnemies.map {
                enemyNode(
                    id: $0, rawValue: snapshot.enemies[$0],
                    playerCount: snapshot.playerCount,
                    engagedInvestigatorID: investigator.id
                )
            }
            if !enemies.isEmpty {
                engagedByInvestigatorID[investigator.id] = enemies
            }
        }
        return (byLocationID, engagedByInvestigatorID)
    }

    private static func orderedInvestigatorsForPlayerAreas(
        in snapshot: PublicGameSnapshot
    ) -> [Investigator] {
        var orderedIDs = snapshot.playerOrder
        let seen = Set(orderedIDs)
        orderedIDs.append(contentsOf: snapshot.investigators.keys
            .filter { !seen.contains($0) }
            .sorted { $0.rawValue.rawValue < $1.rawValue.rawValue })
        return orderedIDs.compactMap { snapshot.investigators[$0] }
    }

    private static func enemyIDs(
        at locationID: LocationID, in snapshot: PublicGameSnapshot
    ) -> [EnemyID] {
        guard let location = snapshot.locations[locationID] else { return [] }
        switch location {
        case let .ordinary(value):
            return value.enemies
        case let .enemy(value):
            return value.enemies
        }
    }

    private static func inPlayCardNode(
        id: BoardPlayerCardID,
        cardID: WireCardID?,
        rawValue: JSONValue?,
        zone: BoardPlayerCardZone,
        ownerID: PlayerID
    ) -> BoardPlayerCardNode {
        let object = entityObject(rawValue, expectedID: id.rawText)
        let code = cardCode(in: object)
        let fallback = code.map { "Card \($0.rawValue)" }
            ?? "\(zone.displayTitle) \(shortID(id.rawText))"
        return BoardPlayerCardNode(
            id: id,
            cardID: cardID,
            cardCode: code,
            displayName: cardDisplayName(in: object, fallback: fallback),
            subtitle: cardSubtitle(in: object),
            zone: zone,
            ownerID: ownerID,
            damage: tokenCount("Damage", in: object?["tokens"]),
            horror: tokenCount("Horror", in: object?["tokens"]),
            usesSummary: usesSummary(fromTokens: object?["tokens"]),
            tokenCounts: safeTokenCounts(in: object?["tokens"]),
            imageReference: code.flatMap(cardImageKey)
        )
    }

    private static func threatTreacheryNode(
        id: TreacheryID,
        rawValue: JSONValue?,
        ownerID: PlayerID
    ) -> BoardThreatTreacheryNode {
        let object = entityObject(rawValue, expectedID: id.codingKey.stringValue)
        let tokens = safeTokenCounts(in: object?["tokens"])
        let code = cardCode(in: object)
        let fallback = code.map { "Card \($0.rawValue)" }
            ?? "Treachery \(shortID(id.codingKey.stringValue))"
        return BoardThreatTreacheryNode(
            id: id,
            cardCode: code,
            displayName: cardDisplayName(in: object, fallback: fallback),
            ownerID: ownerID,
            clueCount: tokens.first { $0.token == "Clue" }?.count ?? 0,
            tokenCounts: tokens
        )
    }

    private static func enemyNode(
        id: EnemyID,
        rawValue: JSONValue?,
        playerCount: Int,
        locationID: LocationID? = nil,
        engagedInvestigatorID: InvestigatorID? = nil
    ) -> BoardEnemyNode {
        let object = entityObject(rawValue, expectedID: id.codingKey.stringValue)
        let code = cardCode(in: object)
        let fallback = code.map { "Card \($0.rawValue)" }
            ?? "Enemy \(shortID(id.codingKey.stringValue))"
        return BoardEnemyNode(
            id: id,
            cardCode: code,
            displayName: cardDisplayName(in: object, fallback: fallback),
            fight: calculationSummary(in: object?["fight"], playerCount: playerCount),
            health: calculationSummary(
                in: object?["health"] ?? object?["remainingHealth"], playerCount: playerCount
            ),
            evade: calculationSummary(in: object?["evade"], playerCount: playerCount),
            damage: tokenCount("Damage", in: object?["tokens"]),
            horror: tokenCount("Horror", in: object?["tokens"]),
            attackDamage: positiveInteger(object?["healthDamage"]),
            attackHorror: positiveInteger(object?["sanityDamage"]),
            exhausted: safeBool(object?["exhausted"]) ?? false,
            engagedInvestigatorID: engagedInvestigatorID,
            locationID: locationID,
            tokenCounts: safeTokenCounts(in: object?["tokens"])
        )
    }

    // MARK: - Shared broad-field parsing

    static func cardImageKey(for cardCode: CardCode) -> AssetKey? {
        guard let artwork = try? AssetIdentifier.artwork(from: cardCode) else { return nil }
        switch artwork {
        case let .official(identifier):
            return AssetKey(category: .card(.art, identifier))
        case let .homebrew(campaign, art):
            return AssetKey(category: .homebrewCard(campaign: campaign, art: art))
        }
    }

    static func cardDisplayName(in object: [String: JSONValue]?, fallback: String) -> String {
        if let label = safeTrimmedString(object?["label"]) {
            return label
        }
        if let name = safeTrimmedString(object?["name"]) {
            return name
        }
        if case let .object(nameObject)? = object?["name"] {
            if let title = safeTrimmedString(nameObject["title"]) {
                return title
            }
        }
        if let title = safeTrimmedString(object?["title"]) {
            return title
        }
        return fallback
    }

    static func cardSubtitle(in object: [String: JSONValue]?) -> String? {
        if case let .object(nameObject)? = object?["name"] {
            if let subtitle = safeTrimmedString(nameObject["subtitle"]) {
                return subtitle
            }
        }
        return safeTrimmedString(object?["subtitle"])
    }

    static func safeTokenCounts(in value: JSONValue?) -> [BoardTokenSummary] {
        guard case let .array(tokens)? = value else { return [] }
        var totals: [String: Int] = [:]
        for token in tokens {
            guard case let .array(contents) = token,
                  contents.count == 2,
                  case let .string(name) = contents[0],
                  let count = safeInteger(contents[1]),
                  count >= 0
            else { continue }
            totals[name] = clampedSum(totals[name] ?? 0, count)
        }
        return totals.map { BoardTokenSummary(token: $0.key, count: $0.value) }
            .sorted { $0.token < $1.token }
    }

    static func usesSummary(fromTokens value: JSONValue?) -> String? {
        let parts = safeTokenCounts(in: value)
            .filter { isUseToken($0.token) && $0.count >= 1 }
            .map { "\($0.token) \($0.count)" }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func tokenCount(_ token: String, in value: JSONValue?) -> Int? {
        let count = safeTokenCounts(in: value).first { $0.token == token }?.count
        guard let count, count > 0 else { return nil }
        return count
    }

    static func usesSummary(in value: JSONValue?) -> String? {
        switch value {
        case let .string(raw):
            return trimmed(raw)
        case let .number(number):
            return safeInteger(.number(number)).map { "Uses \($0)" }
        case let .object(object):
            let parts = object.compactMap { key, value -> String? in
                safeInteger(value).map { "\(BoardDisplayFormatting.humanizeTag(key)) \($0)" }
            }.sorted()
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        case let .array(values):
            let parts = values.compactMap { value -> String? in
                guard case let .array(pair) = value,
                      pair.count == 2,
                      case let .string(name) = pair[0],
                      let count = safeInteger(pair[1])
                else { return nil }
                return "\(name) \(count)"
            }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        case .null, nil, .bool:
            return nil
        }
    }

    static func positiveInteger(_ value: JSONValue?) -> Int? {
        guard let integer = safeInteger(value), integer > 0 else { return nil }
        return integer
    }

    static func safeInteger(_ value: JSONValue?) -> Int? {
        guard case let .number(number)? = value,
              let magnitude = number.wholeNumberMagnitude,
              let parsed = Int(magnitude)
        else { return nil }
        return number.sign == .minus ? -parsed : parsed
    }

    private static func rawObject(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case let .object(object)? = value else { return nil }
        return object
    }

    private static func entityObject(
        _ value: JSONValue?, expectedID: String
    ) -> [String: JSONValue]? {
        guard let object = rawObject(value) else { return nil }
        let embedded = object["id"] ?? object["enemyId"] ?? object["assetId"]
            ?? object["eventId"] ?? object["skillId"] ?? object["treacheryId"]
        guard let embedded else { return object }
        guard case let .string(rawID) = embedded, rawID == expectedID else { return nil }
        return object
    }

    private static func cardCode(in object: [String: JSONValue]?) -> CardCode? {
        guard case let .string(raw)? = object?["cardCode"] ?? object?["card_code"] else {
            return nil
        }
        return try? CardCode(raw)
    }

    private static func rawCardID(in value: JSONValue?) -> WireCardID? {
        guard let object = rawObject(value),
              case let .string(raw)? = object["cardId"] ?? object["cardID"]
        else { return nil }
        return WireCardID(codingKey: AnyCodingKey(stringValue: raw))
    }

    private static func isUseToken(_ token: String) -> Bool {
        token != "Damage" && token != "Horror" && token != "Clue" && token != "Doom"
    }

    private static func clampedSum(_ lhs: Int, _ rhs: Int) -> Int {
        let sum = lhs.addingReportingOverflow(rhs)
        return sum.overflow ? Int.max : sum.partialValue
    }

    private static func safeBool(_ value: JSONValue?) -> Bool? {
        guard case let .bool(value)? = value else { return nil }
        return value
    }

    private static func safeTrimmedString(_ value: JSONValue?) -> String? {
        guard case let .string(raw)? = value else { return nil }
        return trimmed(raw)
    }

    private static func trimmed(_ raw: String) -> String? {
        let result = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func shortID(_ raw: String) -> String {
        String(raw.suffix(8))
    }
}
