@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("ArkhamDB write-back contract")
struct ArkhamDBWriteBackContractTests {
    private let deckID = "00000000-0000-0000-0000-000000000017"

    private func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        try ContractJSON.decode(type, from: ContractJSON.encode(value))
    }

    private func fields(_ value: JSONValue) throws -> [String: JSONValue] {
        guard case let .object(fields) = value else { throw CocoaError(.coderReadCorrupt) }
        return fields
    }

    @Test("Every fixture status decodes its exact state, reason and nullable fields")
    func fixtureStates() throws {
        let statuses = try arkhamDBWriteBackStateRows().map {
            try decode(ArkhamDBWriteBackStatus.self, $0)
        }
        #expect(statuses.map(\.state) == [
            .succeeded, .conflict, .failed, .cancelled, .conflict, .conflict, .conflict, .conflict,
        ])
        #expect(statuses.map(\.conflict?.reason) == [
            nil, .remoteChanged, nil, nil, .pushUncertain, .targetAlreadyLinked,
            .boundaryUndone, .accountChanged,
        ])
        #expect(statuses.map(\.remoteDeckId) == ["124"] + Array(repeating: "123", count: 7))
        #expect(statuses.map(\.enabled) == [true, true, true, false, true, true, true, true])
        #expect(statuses.map(\.error) == [
            nil, "remoteChanged", "remoteUnavailable", nil, "pushUncertain",
            "targetAlreadyLinked", "boundaryUndone", "accountChanged",
        ])
        let first = try #require(statuses.first)
        #expect(first.localDeckId.description == deckID.uppercased())
        #expect(first.resultingLocalDeckId == first.localDeckId)
        #expect(first.pushId == "00000000-0000-0000-0000-0000000000f5")
        #expect(first.campaignKey == "game/iid")
        #expect(statuses.allSatisfy { !$0.spentXpSynced })
        let remoteChanged = try #require(statuses[1].conflict)
        #expect(remoteChanged.lastSyncedDateUpdate == "2026-10-19T11:00:00Z")
        #expect(remoteChanged.lastSyncedVersion == "1.0")
        #expect(remoteChanged.remoteDateUpdate == "edited")
        #expect(remoteChanged.remoteVersion == "1.0")
        let undone = try #require(statuses[6].conflict)
        #expect(undone.lastSyncedDateUpdate == "created")
        #expect(undone.lastSyncedVersion == "2.0")
        #expect(undone.remoteDateUpdate == nil && undone.remoteVersion == nil)
    }

    @Test("Every fixture status round-trips to the exact governed JSON")
    func statusRoundTrip() throws {
        for row in try arkhamDBWriteBackStateRows() {
            let status = try decode(ArkhamDBWriteBackStatus.self, row)
            let encoded = try ContractJSON.encode(status)
            #expect(try ContractJSON.decode(JSONValue.self, from: encoded) == row)
            #expect(try ContractJSON.decode(ArkhamDBWriteBackStatus.self, from: encoded) == status)
        }
    }

    @Test("Toggle and resolve requests encode exactly the governed request bodies")
    func requests() throws {
        let cases: [(String, ArkhamDBResolveConflictRequest)] = try [
            ("keepRemoteRequest", .init(resolution: .keepRemote, confirmed: false)),
            ("overwriteRequest", .init(resolution: .overwrite, confirmed: true)),
            ("saveAsNewRequest", .init(resolution: .saveAsNew, confirmed: true)),
        ]
        for (key, request) in cases {
            let fixture = try arkhamDBWriteBackFixture(key)
            #expect(try decode(ArkhamDBResolveConflictRequest.self, fixture) == request)
            #expect(try ContractJSON.encode(request) == ContractJSON.encode(fixture))
        }
        let toggle = try arkhamDBWriteBackFixture("toggleRequest")
        #expect(try decode(ArkhamDBWriteBackToggleRequest.self, toggle) == .init(enabled: true))
        #expect(try ContractJSON.encode(ArkhamDBWriteBackToggleRequest(enabled: true))
            == ContractJSON.encode(toggle))
        #expect(try ContractJSON.encode(ArkhamDBWriteBackToggleRequest(enabled: false))
            == Data(#"{"enabled":false}"#.utf8))
    }

    @Test("Overwrite and save-as-new cannot be built or decoded without confirmation")
    func confirmation() throws {
        for resolution in [ArkhamDBWriteBackResolution.overwrite, .saveAsNew] {
            #expect(resolution.requiresConfirmation)
            #expect(throws: ArkhamDBResolveConflictRequest.ValidationError.confirmationRequired) {
                try ArkhamDBResolveConflictRequest(resolution: resolution, confirmed: false)
            }
            for confirmed: JSONValue? in [nil, .bool(false), .null, .string("true")] {
                var body: [String: JSONValue] = ["resolution": .string(resolution.rawValue)]
                body["confirmed"] = confirmed
                #expect(throws: (any Error).self) {
                    try decode(ArkhamDBResolveConflictRequest.self, .object(body))
                }
            }
        }
        #expect(!ArkhamDBWriteBackResolution.keepRemote.requiresConfirmation)
        let keep = try decode(
            ArkhamDBResolveConflictRequest.self,
            .object(["resolution": .string("keepRemote")])
        )
        let unconfirmedKeep = try ArkhamDBResolveConflictRequest(
            resolution: .keepRemote,
            confirmed: false
        )
        #expect(keep == unconfirmedKeep)
        #expect(throws: (any Error).self) {
            try decode(
                ArkhamDBResolveConflictRequest.self,
                .object(["resolution": .string("discard"), "confirmed": .bool(true)])
            )
        }
    }

    @Test("Unknown states, conflict reasons and error codes are preserved, not rejected")
    func unknownFallbacks() throws {
        var row = try fields(#require(arkhamDBWriteBackStateRows().first))
        row["state"] = .string("paused")
        let paused = try decode(ArkhamDBWriteBackStatus.self, .object(row))
        #expect(paused.state == .unknown("paused"))
        #expect(try ContractJSON.decode(JSONValue.self, from: ContractJSON.encode(paused))
            == .object(row))
        var conflictRow = try fields(arkhamDBWriteBackStateRows()[1])
        var conflict = try fields(#require(conflictRow["conflict"]))
        conflict["reason"] = .string("remoteDeleted")
        conflictRow["conflict"] = .object(conflict)
        #expect(try decode(ArkhamDBWriteBackStatus.self, .object(conflictRow)).conflict?
            .reason == .unknown("remoteDeleted"))
        let error = try decode(
            ArkhamDBError.self,
            .object(["code": .string("quotaExceeded"), "error": .string("message")])
        )
        #expect(error.code == .unknown("quotaExceeded"))
    }

    @Test("Status and conflict keys are required; nullable keys accept null; types are strict")
    func strictKeys() throws {
        let rows = try arkhamDBWriteBackStateRows()
        let status = try fields(rows[1])
        let conflict = try fields(#require(status["conflict"]))
        for key in status.keys {
            var missing = status
            missing.removeValue(forKey: key)
            #expect(throws: (any Error).self, "Missing \(key)") {
                try decode(ArkhamDBWriteBackStatus.self, .object(missing))
            }
            var invalid = status
            invalid[key] = .array([])
            #expect(throws: (any Error).self, "Wrong type \(key)") {
                try decode(ArkhamDBWriteBackStatus.self, .object(invalid))
            }
        }
        for key in conflict.keys {
            var missing = conflict
            missing.removeValue(forKey: key)
            #expect(throws: (any Error).self, "Missing conflict.\(key)") {
                try decode(ArkhamDBWriteBackConflict.self, .object(missing))
            }
        }
        for key in ["localDeckId", "remoteDeckId", "enabled", "state", "spentXpSynced"] {
            var nulled = status
            nulled[key] = .null
            #expect(throws: (any Error).self, "Null \(key)") {
                try decode(ArkhamDBWriteBackStatus.self, .object(nulled))
            }
        }
        var nullable = try fields(rows[0])
        for key in ["pushId", "campaignKey", "error", "resultingLocalDeckId"] {
            nullable[key] = .null
        }
        let decoded = try decode(ArkhamDBWriteBackStatus.self, .object(nullable))
        #expect(decoded.pushId == nil && decoded.campaignKey == nil)
        #expect(decoded.error == nil && decoded.resultingLocalDeckId == nil)
        for invalid in ["", "12a", "-1", " 123"] {
            var bad = status
            bad["remoteDeckId"] = .string(invalid)
            #expect(throws: (any Error).self) {
                try decode(ArkhamDBWriteBackStatus.self, .object(bad))
            }
        }
    }

    @Test("A conflict object is required exactly when the known state is conflict")
    func conflictInvariant() throws {
        let rows = try arkhamDBWriteBackStateRows()
        var conflictWithoutObject = try fields(rows[1])
        conflictWithoutObject["conflict"] = .null
        #expect(throws: (any Error).self) {
            try decode(ArkhamDBWriteBackStatus.self, .object(conflictWithoutObject))
        }
        var succeededWithObject = try fields(rows[0])
        succeededWithObject["conflict"] = try fields(rows[1])["conflict"]
        #expect(throws: (any Error).self) {
            try decode(ArkhamDBWriteBackStatus.self, .object(succeededWithObject))
        }
        succeededWithObject["state"] = .string("paused")
        #expect(try decode(ArkhamDBWriteBackStatus.self, .object(succeededWithObject))
            .conflict?.reason == .remoteChanged)
    }

    @Test("Status deckLinks: missing is empty; null or wrong type throws; rows decode")
    func statusDeckLinks() throws {
        let linked = try arkhamDBFixtureData("linkedStatus")
        var status = try ContractJSON.decode([String: JSONValue].self, from: linked)
        #expect(status["deckLinks"] == nil)
        let legacy = try ContractJSON.decode(ArkhamDBLinkStatus.self, from: linked)
        #expect(legacy.deckLinks.isEmpty)
        #expect(legacy.skippedDeckLinkCount == 0)
        for invalid: JSONValue in [.null, .object([:]), .string("[]"), .bool(false)] {
            status["deckLinks"] = invalid
            #expect(throws: (any Error).self) {
                try decode(ArkhamDBLinkStatus.self, .object(status))
            }
        }
        status["deckLinks"] = .array([])
        let empty = try decode(ArkhamDBLinkStatus.self, .object(status))
        #expect(empty.deckLinks.isEmpty && empty.skippedDeckLinkCount == 0)
        let rows = try arkhamDBWriteBackStateRows()
        status["deckLinks"] = .array(rows)
        let populated = try decode(ArkhamDBLinkStatus.self, .object(status))
        #expect(populated.deckLinks.count == 8)
        #expect(populated.skippedDeckLinkCount == 0)
        #expect(populated.deckLinks.map(\.state).last == .conflict)
        #expect(populated.deckLinks.last?.conflict?.reason == .accountChanged)
        #expect(try ContractJSON.decode(JSONValue.self, from: ContractJSON.encode(populated))
            == .object(status))
    }

    @Test("One unreadable deck link is skipped and counted, like the remote deck list")
    func statusDeckLinkTolerance() throws {
        var status = try ContractJSON.decode(
            [String: JSONValue].self,
            from: arkhamDBFixtureData("linkedStatus")
        )
        let rows = try arkhamDBWriteBackStateRows()
        var broken = try fields(rows[1])
        broken["conflict"] = .null
        status["deckLinks"] = .array([rows[0], .object(broken), .null, rows[7]])
        let decoded = try decode(ArkhamDBLinkStatus.self, .object(status))
        #expect(decoded.deckLinks.map(\.state) == [.succeeded, .conflict])
        #expect(decoded.deckLinks.map(\.remoteDeckId) == ["124", "123"])
        #expect(decoded.skippedDeckLinkCount == 2)
        #expect(decoded.linked)
    }
}

@Suite("ArkhamDB error code wire spellings")
struct ArkhamDBErrorCodeWireTests {
    @Test("Every known error code has its exact unique wire spelling and round-trips")
    func errorCodeWireSpellings() throws {
        let expected: [(String, ArkhamDBErrorCode)] = [
            ("disabled", .disabled), ("oauthCallbackInvalidState", .oauthCallbackInvalidState),
            ("notLinked", .notLinked), ("tokenExpired", .tokenExpired), ("notFound", .notFound),
            ("storageFailure", .storageFailure), ("remoteUnavailable", .remoteUnavailable),
            ("oauthCompletionInvalid", .oauthCompletionInvalid),
            ("writeBackDisabled", .writeBackDisabled), ("conflict", .conflict),
            ("pushUncertain", .pushUncertain), ("validationFailed", .validationFailed),
        ]
        #expect(ArkhamDBErrorCode.allKnown == expected.map(\.1))
        let spellings = ArkhamDBErrorCode.allKnown.map(\.rawValue)
        #expect(spellings == expected.map(\.0))
        #expect(Set(spellings).count == 12)
        #expect(!spellings.contains(""))
        for code in ArkhamDBErrorCode.allKnown {
            let body = JSONValue.object(["code": .string(code.rawValue), "error": .string("m")])
            let error = try ContractJSON.decode(ArkhamDBError.self, from: ContractJSON.encode(body))
            #expect(error.code == code)
            #expect(error.requiresRelinking == (code == .notLinked || code == .tokenExpired))
            #expect(try ContractJSON.decode(JSONValue.self, from: ContractJSON.encode(error))
                == body)
            #expect(ArkhamDBErrorCode(rawValue: code.rawValue) == code)
        }
        #expect(ArkhamDBErrorCode(rawValue: "quotaExceeded").rawValue == "quotaExceeded")
    }
}
