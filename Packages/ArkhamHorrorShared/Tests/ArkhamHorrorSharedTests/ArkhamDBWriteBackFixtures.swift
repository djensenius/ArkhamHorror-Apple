@testable import ArkhamHorrorShared
import Foundation
import Testing

// Byte-for-byte copies of the schema 0.1.55 fixtures from fork PR #219
// (`contracts/fixtures/arkhamdb-write-back.json` and `capabilities-arkhamdb.json`).
// The pin stays at 0.1.54 until that PR merges; the final repin replaces these inline
// copies with the vendored `Fixtures/Contract` files.

let arkhamDBWriteBackFixtureJSON = #"""
{
  "keepRemoteRequest": {
    "confirmed": false,
    "resolution": "keepRemote"
  },
  "overwriteRequest": {
    "confirmed": true,
    "resolution": "overwrite"
  },
  "saveAsNewRequest": {
    "confirmed": true,
    "resolution": "saveAsNew"
  },
  "states": [
    {
      "campaignKey": "game/iid",
      "conflict": null,
      "enabled": true,
      "error": null,
      "localDeckId": "00000000-0000-0000-0000-000000000017",
      "pushId": "00000000-0000-0000-0000-0000000000f5",
      "remoteDeckId": "124",
      "resultingLocalDeckId": "00000000-0000-0000-0000-000000000017",
      "spentXpSynced": false,
      "state": "succeeded"
    },
    {
      "campaignKey": "game/iid",
      "conflict": {
        "lastSyncedDateUpdate": "2026-10-19T11:00:00Z",
        "lastSyncedVersion": "1.0",
        "reason": "remoteChanged",
        "remoteDateUpdate": "edited",
        "remoteVersion": "1.0"
      },
      "enabled": true,
      "error": "remoteChanged",
      "localDeckId": "00000000-0000-0000-0000-000000000017",
      "pushId": "00000000-0000-0000-0000-0000000000f5",
      "remoteDeckId": "123",
      "resultingLocalDeckId": "00000000-0000-0000-0000-000000000017",
      "spentXpSynced": false,
      "state": "conflict"
    },
    {
      "campaignKey": "game/iid",
      "conflict": null,
      "enabled": true,
      "error": "remoteUnavailable",
      "localDeckId": "00000000-0000-0000-0000-000000000017",
      "pushId": "00000000-0000-0000-0000-0000000000f5",
      "remoteDeckId": "123",
      "resultingLocalDeckId": "00000000-0000-0000-0000-000000000017",
      "spentXpSynced": false,
      "state": "failed"
    },
    {
      "campaignKey": "game/iid",
      "conflict": null,
      "enabled": false,
      "error": null,
      "localDeckId": "00000000-0000-0000-0000-000000000017",
      "pushId": "00000000-0000-0000-0000-0000000000f5",
      "remoteDeckId": "123",
      "resultingLocalDeckId": "00000000-0000-0000-0000-000000000017",
      "spentXpSynced": false,
      "state": "cancelled"
    },
    {
      "campaignKey": "game/iid",
      "conflict": {
        "lastSyncedDateUpdate": "2026-10-19T11:00:00Z",
        "lastSyncedVersion": "1.0",
        "reason": "pushUncertain",
        "remoteDateUpdate": "2026-10-19T11:00:00Z",
        "remoteVersion": "1.0"
      },
      "enabled": true,
      "error": "pushUncertain",
      "localDeckId": "00000000-0000-0000-0000-000000000017",
      "pushId": "00000000-0000-0000-0000-0000000000f5",
      "remoteDeckId": "123",
      "resultingLocalDeckId": "00000000-0000-0000-0000-000000000017",
      "spentXpSynced": false,
      "state": "conflict"
    },
    {
      "campaignKey": "game/iid",
      "conflict": {
        "lastSyncedDateUpdate": "2026-10-19T11:00:00Z",
        "lastSyncedVersion": "1.0",
        "reason": "targetAlreadyLinked",
        "remoteDateUpdate": "2026-10-19T11:00:00Z",
        "remoteVersion": "1.0"
      },
      "enabled": true,
      "error": "targetAlreadyLinked",
      "localDeckId": "00000000-0000-0000-0000-000000000017",
      "pushId": "00000000-0000-0000-0000-0000000000f5",
      "remoteDeckId": "123",
      "resultingLocalDeckId": "00000000-0000-0000-0000-000000000017",
      "spentXpSynced": false,
      "state": "conflict"
    },
    {
      "campaignKey": "game/iid",
      "conflict": {
        "lastSyncedDateUpdate": "created",
        "lastSyncedVersion": "2.0",
        "reason": "boundaryUndone",
        "remoteDateUpdate": null,
        "remoteVersion": null
      },
      "enabled": true,
      "error": "boundaryUndone",
      "localDeckId": "00000000-0000-0000-0000-000000000017",
      "pushId": "00000000-0000-0000-0000-0000000000f5",
      "remoteDeckId": "123",
      "resultingLocalDeckId": "00000000-0000-0000-0000-000000000017",
      "spentXpSynced": false,
      "state": "conflict"
    },
    {
      "campaignKey": "game/iid",
      "conflict": {
        "lastSyncedDateUpdate": "created",
        "lastSyncedVersion": "2.0",
        "reason": "accountChanged",
        "remoteDateUpdate": null,
        "remoteVersion": null
      },
      "enabled": true,
      "error": "accountChanged",
      "localDeckId": "00000000-0000-0000-0000-000000000017",
      "pushId": "00000000-0000-0000-0000-0000000000f5",
      "remoteDeckId": "123",
      "resultingLocalDeckId": "00000000-0000-0000-0000-000000000017",
      "spentXpSynced": false,
      "state": "conflict"
    }
  ],
  "toggleRequest": {
    "enabled": true
  }
}

"""#

let arkhamDBWriteBackCapabilitiesJSON = #"""
{
  "schemaRevision": "0.1.55",
  "status": "baseline-incomplete",
  "apiBasePath": "/api/v1",
  "nativeClientMinimumRevision": "0.1.53",
  "capabilities": [
    "arkham.campaign-catalog.v1",
    "arkhamdb.account-linking.v1",
    "arkhamdb.write-back.v1",
    "events.shared-state-versioning",
    "games.step-probe",
    "questions.semantic-presentation.v2",
    "websockets.authorization-header",
    "websockets.spectator-read-only"
  ],
  "campaignCatalog": {
    "endpoint": "/api/v1/arkham/campaign-catalog",
    "catalogRevision": "1.0123456789abcdef0123456789abcdef",
    "schemaVersion": "1.0.0",
    "digestAlgorithm": "sha256"
  }
}

"""#

func arkhamDBWriteBackFixture(_ key: String) throws -> JSONValue {
    let root = try ContractJSON.decode(
        [String: JSONValue].self,
        from: Data(arkhamDBWriteBackFixtureJSON.utf8)
    )
    return try #require(root[key])
}

func arkhamDBWriteBackStateRows() throws -> [JSONValue] {
    guard case let .array(rows) = try arkhamDBWriteBackFixture("states") else {
        throw CocoaError(.coderReadCorrupt)
    }
    return rows
}
