import Foundation

private struct BoardPlayerCardIdentity: Sendable, Equatable {
    let id: WireCardID
    let cardCode: CardCode
    let displayName: String
    let subtitle: String?
    let tokenCounts: [BoardTokenSummary]
    let damage: Int?
    let horror: Int?
    let usesSummary: String?

    init?(_ rawValue: JSONValue) {
        guard case let .object(wrapper) = rawValue,
              Set(wrapper.keys) == ["tag", "contents"],
              wrapper["tag"] == .string("PlayerCard"),
              case let .object(contents)? = wrapper["contents"],
              case let .string(rawID)? = contents["id"],
              let id = WireCardID(codingKey: AnyCodingKey(stringValue: rawID)),
              case let .string(rawCardCode)? = contents["cardCode"],
              let cardCode = try? CardCode(rawCardCode)
        else { return nil }
        self.id = id
        self.cardCode = cardCode
        displayName = BoardProjectionBuilder.cardDisplayName(
            in: contents, fallback: "Card \(cardCode.rawValue)"
        )
        subtitle = BoardProjectionBuilder.cardSubtitle(in: contents)
        tokenCounts = BoardProjectionBuilder.safeTokenCounts(in: contents["tokens"])
        damage = BoardProjectionBuilder.safeInteger(contents["damage"])
        horror = BoardProjectionBuilder.safeInteger(contents["horror"])
        usesSummary = BoardProjectionBuilder.usesSummary(in: contents["uses"])
    }

    static func claimedID(in rawValue: JSONValue) -> WireCardID? {
        guard case let .object(wrapper) = rawValue,
              case let .object(contents)? = wrapper["contents"],
              case let .string(rawID)? = contents["id"]
        else { return nil }
        return WireCardID(codingKey: AnyCodingKey(stringValue: rawID))
    }
}

private struct BoardInvestigatorHandRecord: Sendable {
    let mapID: InvestigatorID
    let investigator: Investigator
}

extension BoardProjectionBuilder {
    /// Builds only cards whose ownership and identity agree across every authoritative
    /// surface needed by a mulligan prompt. Ambiguous investigators, duplicate hand IDs,
    /// cross-player ownership conflicts, malformed card wrappers, map-key/embedded-ID
    /// disagreement, and card-code disagreement all fail closed.
    static func makeHandCards(
        from snapshot: PublicGameSnapshot
    ) -> [PlayerID: [WireCardID: BoardHandCardNode]] {
        makeResolvedHandCards(from: snapshot).legacy
    }

    static func makeOrderedHandCards(
        from snapshot: PublicGameSnapshot
    ) -> [PlayerID: [BoardPlayerCardNode]] {
        makeResolvedHandCards(from: snapshot).ordered
    }

    private static func makeResolvedHandCards(
        from snapshot: PublicGameSnapshot
    ) -> (
        legacy: [PlayerID: [WireCardID: BoardHandCardNode]],
        ordered: [PlayerID: [BoardPlayerCardNode]]
    ) {
        let records = investigatorHandRecords(in: snapshot)
        let investigatorsByPlayer = validInvestigatorsByPlayer(in: records)
        let globalCards = globalPlayerCards(in: snapshot)
        let parsedHands = parsedHands(in: investigatorsByPlayer)
        let claimCounts = cardClaimCounts(in: records)
        return resolvedHandCards(
            parsedHands,
            globalCards: globalCards,
            claimCounts: claimCounts
        )
    }

    private static func investigatorHandRecords(
        in snapshot: PublicGameSnapshot
    ) -> [BoardInvestigatorHandRecord] {
        func records(
            in investigators: [InvestigatorID: Investigator]
        ) -> [BoardInvestigatorHandRecord] {
            investigators.map {
                BoardInvestigatorHandRecord(mapID: $0.key, investigator: $0.value)
            }
        }
        return records(in: snapshot.investigators)
            + records(in: snapshot.otherInvestigators)
            + records(in: snapshot.killedInvestigators)
    }

    private static func validInvestigatorsByPlayer(
        in records: [BoardInvestigatorHandRecord]
    ) -> [PlayerID: Investigator] {
        let recordsByPlayer = Dictionary(grouping: records, by: \.investigator.playerID)
        let recordsByMapID = Dictionary(grouping: records, by: \.mapID)
        let recordsByEmbeddedID = Dictionary(grouping: records, by: \.investigator.id)
        var result: [PlayerID: Investigator] = [:]
        for (playerID, playerRecords) in recordsByPlayer where playerRecords.count == 1 {
            let record = playerRecords[0]
            guard record.mapID == record.investigator.id,
                  recordsByMapID[record.mapID]?.count == 1,
                  recordsByEmbeddedID[record.investigator.id]?.count == 1
            else { continue }
            result[playerID] = record.investigator
        }
        return result
    }

    private static func globalPlayerCards(
        in snapshot: PublicGameSnapshot
    ) -> [WireCardID: BoardPlayerCardIdentity] {
        var globalCards: [WireCardID: BoardPlayerCardIdentity] = [:]
        for (mapID, rawCard) in snapshot.cards {
            guard let card = BoardPlayerCardIdentity(rawCard), card.id == mapID else { continue }
            globalCards[mapID] = card
        }
        return globalCards
    }

    private static func parsedHands(
        in investigatorsByPlayer: [PlayerID: Investigator]
    ) -> [PlayerID: [WireCardID: BoardPlayerCardIdentity]] {
        var parsedHands: [PlayerID: [WireCardID: BoardPlayerCardIdentity]] = [:]
        for (playerID, investigator) in investigatorsByPlayer {
            var cards: [WireCardID: BoardPlayerCardIdentity] = [:]
            for rawCard in investigator.hand {
                guard let card = BoardPlayerCardIdentity(rawCard) else { continue }
                cards[card.id] = card
            }
            parsedHands[playerID] = cards
        }
        return parsedHands
    }

    private static func cardClaimCounts(
        in records: [BoardInvestigatorHandRecord]
    ) -> [WireCardID: Int] {
        var counts: [WireCardID: Int] = [:]
        for record in records {
            for rawCard in record.investigator.hand {
                guard let cardID = BoardPlayerCardIdentity.claimedID(in: rawCard) else { continue }
                counts[cardID, default: 0] += 1
            }
        }
        return counts
    }

    private static func resolvedHandCards(
        _ parsedHands: [PlayerID: [WireCardID: BoardPlayerCardIdentity]],
        globalCards: [WireCardID: BoardPlayerCardIdentity],
        claimCounts: [WireCardID: Int]
    ) -> (
        legacy: [PlayerID: [WireCardID: BoardHandCardNode]],
        ordered: [PlayerID: [BoardPlayerCardNode]]
    ) {
        var legacyResult: [PlayerID: [WireCardID: BoardHandCardNode]] = [:]
        var orderedResult: [PlayerID: [BoardPlayerCardNode]] = [:]
        for (playerID, hand) in parsedHands {
            var legacy: [WireCardID: BoardHandCardNode] = [:]
            var ordered: [BoardPlayerCardNode] = []
            let sortedCardIDs = hand.keys.sorted {
                $0.codingKey.stringValue < $1.codingKey.stringValue
            }
            for cardID in sortedCardIDs {
                guard let handCard = hand[cardID],
                      claimCounts[cardID] == 1,
                      let globalCard = globalCards[cardID],
                      globalCard.cardCode == handCard.cardCode
                else { continue }
                let displayName = globalCard.displayName
                legacy[cardID] = BoardHandCardNode(
                    id: cardID,
                    cardCode: handCard.cardCode,
                    displayName: displayName
                )
                ordered.append(BoardPlayerCardNode(
                    id: .card(cardID),
                    cardID: cardID,
                    cardCode: handCard.cardCode,
                    displayName: displayName,
                    subtitle: globalCard.subtitle,
                    zone: .hand,
                    ownerID: playerID,
                    damage: globalCard.damage,
                    horror: globalCard.horror,
                    usesSummary: globalCard.usesSummary,
                    tokenCounts: globalCard.tokenCounts,
                    imageReference: nil
                ))
            }
            legacyResult[playerID] = legacy
            orderedResult[playerID] = ordered
        }
        return (legacyResult, orderedResult)
    }
}
