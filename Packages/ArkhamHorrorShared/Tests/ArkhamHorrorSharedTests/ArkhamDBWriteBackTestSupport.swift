@testable import ArkhamHorrorShared
import Foundation
import Testing

// Shared fixtures for the ArkhamDB write-back view-model suites.

func writeBackRow(
    _ id: DeckID,
    enabled: Bool = true,
    state: ArkhamDBWriteBackState = .idle,
    reason: ArkhamDBWriteBackConflictReason? = nil,
    error: String? = nil,
    resulting: DeckID? = nil,
    spentXpSynced: Bool = false
) -> ArkhamDBWriteBackStatus {
    ArkhamDBWriteBackStatus(
        localDeckId: id, remoteDeckId: "123", enabled: enabled, state: state,
        pushId: nil, campaignKey: nil, error: error,
        conflict: reason.map {
            ArkhamDBWriteBackConflict(
                reason: $0, lastSyncedDateUpdate: nil, lastSyncedVersion: nil,
                remoteDateUpdate: nil, remoteVersion: nil
            )
        },
        resultingLocalDeckId: resulting, spentXpSynced: spentXpSynced
    )
}

func writeBackStatusData(_ rows: [ArkhamDBWriteBackStatus]) throws -> Data {
    try ContractJSON.encode(ArkhamDBLinkStatus(
        linked: true, remoteAccountId: "7", remoteAccountName: "Agnes",
        tokenExpiry: nil, linkedAt: nil,
        writeBackEnabledDeckCount: rows.count { $0.enabled },
        deckLinks: rows, skippedDeckLinkCount: 0
    ))
}

func writeBackBody(_ request: URLRequest) throws -> JSONValue {
    try ContractJSON.decode(JSONValue.self, from: #require(request.httpBody))
}
