/// The durable campaign push state for one linked deck. Unknown future states are preserved.
enum ArkhamDBWriteBackState: Sendable, Hashable, Codable {
    case idle
    case pending
    case running
    case failed
    case conflict
    case succeeded
    case cancelled
    case unknown(String)

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = switch raw {
        case "idle": .idle
        case "pending": .pending
        case "running": .running
        case "failed": .failed
        case "conflict": .conflict
        case "succeeded": .succeeded
        case "cancelled": .cancelled
        default: .unknown(raw)
        }
    }

    func encode(to encoder: any Encoder) throws {
        let raw: String = switch self {
        case .idle: "idle"
        case .pending: "pending"
        case .running: "running"
        case .failed: "failed"
        case .conflict: "conflict"
        case .succeeded: "succeeded"
        case .cancelled: "cancelled"
        case let .unknown(raw): raw
        }
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// Why a push stopped for explicit resolution. Unknown future reasons are preserved.
enum ArkhamDBWriteBackConflictReason: Sendable, Hashable, Codable {
    case remoteChanged
    case campaignChanged
    case pushUncertain
    case targetAlreadyLinked
    /// A durable accounting fence: retry and every resolution are refused (HTTP 409).
    case boundaryUndone
    /// A durable accounting fence: retry and every resolution are refused (HTTP 409).
    case accountChanged
    case unknown(String)

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = switch raw {
        case "remoteChanged": .remoteChanged
        case "campaignChanged": .campaignChanged
        case "pushUncertain": .pushUncertain
        case "targetAlreadyLinked": .targetAlreadyLinked
        case "boundaryUndone": .boundaryUndone
        case "accountChanged": .accountChanged
        default: .unknown(raw)
        }
    }

    func encode(to encoder: any Encoder) throws {
        let raw: String = switch self {
        case .remoteChanged: "remoteChanged"
        case .campaignChanged: "campaignChanged"
        case .pushUncertain: "pushUncertain"
        case .targetAlreadyLinked: "targetAlreadyLinked"
        case .boundaryUndone: "boundaryUndone"
        case .accountChanged: "accountChanged"
        case let .unknown(raw): raw
        }
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

struct ArkhamDBWriteBackConflict: Sendable, Equatable {
    let reason: ArkhamDBWriteBackConflictReason
    let lastSyncedDateUpdate: String?
    let lastSyncedVersion: String?
    let remoteDateUpdate: String?
    let remoteVersion: String?
}

extension ArkhamDBWriteBackConflict: Codable {
    private enum CodingKeys: String, CodingKey {
        case reason
        case lastSyncedDateUpdate
        case lastSyncedVersion
        case remoteDateUpdate
        case remoteVersion
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reason = try container.decode(ArkhamDBWriteBackConflictReason.self, forKey: .reason)
        func nullable(_ key: CodingKeys) throws -> String? {
            try decodeRequiredNullable(
                String.self,
                from: container,
                forKey: key,
                codingPath: decoder.codingPath
            )
        }
        lastSyncedDateUpdate = try nullable(.lastSyncedDateUpdate)
        lastSyncedVersion = try nullable(.lastSyncedVersion)
        remoteDateUpdate = try nullable(.remoteDateUpdate)
        remoteVersion = try nullable(.remoteVersion)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reason, forKey: .reason)
        try container.encode(lastSyncedDateUpdate, forKey: .lastSyncedDateUpdate)
        try container.encode(lastSyncedVersion, forKey: .lastSyncedVersion)
        try container.encode(remoteDateUpdate, forKey: .remoteDateUpdate)
        try container.encode(remoteVersion, forKey: .remoteVersion)
    }
}

/// Per-deck write-back status. `error` is free server text and must not be shown verbatim.
struct ArkhamDBWriteBackStatus: Sendable, Equatable {
    let localDeckId: DeckID
    let remoteDeckId: String
    let enabled: Bool
    let state: ArkhamDBWriteBackState
    let pushId: String?
    let campaignKey: String?
    let error: String?
    let conflict: ArkhamDBWriteBackConflict?
    let resultingLocalDeckId: DeckID?
    /// Always false today: spent XP must still be set manually on ArkhamDB.
    let spentXpSynced: Bool
}

extension ArkhamDBWriteBackStatus: Codable {
    private enum CodingKeys: String, CodingKey {
        case localDeckId
        case remoteDeckId
        case enabled
        case state
        case pushId
        case campaignKey
        case error
        case conflict
        case resultingLocalDeckId
        case spentXpSynced
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        localDeckId = try container.decode(DeckID.self, forKey: .localDeckId)
        remoteDeckId = try container.decode(String.self, forKey: .remoteDeckId)
        guard !remoteDeckId.isEmpty, remoteDeckId.utf8.allSatisfy({ (48 ... 57).contains($0) })
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .remoteDeckId,
                in: container,
                debugDescription: "ArkhamDB remoteDeckId must match ^[0-9]+$"
            )
        }
        enabled = try container.decode(Bool.self, forKey: .enabled)
        state = try container.decode(ArkhamDBWriteBackState.self, forKey: .state)
        pushId = try decodeRequiredNullable(
            String.self, from: container, forKey: .pushId, codingPath: decoder.codingPath
        )
        campaignKey = try decodeRequiredNullable(
            String.self, from: container, forKey: .campaignKey, codingPath: decoder.codingPath
        )
        error = try decodeRequiredNullable(
            String.self, from: container, forKey: .error, codingPath: decoder.codingPath
        )
        conflict = try decodeRequiredNullable(
            ArkhamDBWriteBackConflict.self,
            from: container,
            forKey: .conflict,
            codingPath: decoder.codingPath
        )
        resultingLocalDeckId = try decodeRequiredNullable(
            DeckID.self,
            from: container,
            forKey: .resultingLocalDeckId,
            codingPath: decoder.codingPath
        )
        spentXpSynced = try container.decode(Bool.self, forKey: .spentXpSynced)
        // The contract requires a conflict object exactly when state is conflict; an
        // unknown future state is not constrained.
        let requiresConflict: Bool? = switch state {
        case .conflict: true
        case .unknown: nil
        default: false
        }
        if let requiresConflict, requiresConflict != (conflict != nil) {
            throw DecodingError.dataCorruptedError(
                forKey: .conflict,
                in: container,
                debugDescription: "conflict must be an object exactly when state is conflict"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(localDeckId, forKey: .localDeckId)
        try container.encode(remoteDeckId, forKey: .remoteDeckId)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(state, forKey: .state)
        try container.encode(pushId, forKey: .pushId)
        try container.encode(campaignKey, forKey: .campaignKey)
        try container.encode(error, forKey: .error)
        try container.encode(conflict, forKey: .conflict)
        try container.encode(resultingLocalDeckId, forKey: .resultingLocalDeckId)
        try container.encode(spentXpSynced, forKey: .spentXpSynced)
    }
}

/// `PUT /arkham/arkhamdb/decks/{id}/write-back` body.
struct ArkhamDBWriteBackToggleRequest: Sendable, Equatable, Codable {
    let enabled: Bool
}

enum ArkhamDBWriteBackResolution: String, Sendable, Hashable, Codable, CaseIterable {
    case keepRemote
    case overwrite
    case saveAsNew

    /// Overwrite and save-as-new change ArkhamDB and need an explicit user confirmation.
    var requiresConfirmation: Bool {
        self != .keepRemote
    }
}

/// `POST /arkham/arkhamdb/decks/{id}/resolve-conflict` body. Construction refuses an
/// unconfirmed overwrite or save-as-new, so no such request can ever be sent.
struct ArkhamDBResolveConflictRequest: Sendable, Equatable {
    let resolution: ArkhamDBWriteBackResolution
    let confirmed: Bool

    enum ValidationError: Error, Equatable { case confirmationRequired }

    init(resolution: ArkhamDBWriteBackResolution, confirmed: Bool) throws {
        guard !resolution.requiresConfirmation || confirmed else {
            throw ValidationError.confirmationRequired
        }
        self.resolution = resolution
        self.confirmed = confirmed
    }
}

extension ArkhamDBResolveConflictRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case resolution
        case confirmed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let resolution = try container.decode(
            ArkhamDBWriteBackResolution.self,
            forKey: .resolution
        )
        // `confirmed` is optional for keepRemote only; when present it must be a Bool.
        let confirmed = container.contains(.confirmed)
            ? try container.decode(Bool.self, forKey: .confirmed)
            : false
        do {
            try self.init(resolution: resolution, confirmed: confirmed)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .confirmed,
                in: container,
                debugDescription: "overwrite and saveAsNew require confirmed=true"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(resolution, forKey: .resolution)
        try container.encode(confirmed, forKey: .confirmed)
    }
}
