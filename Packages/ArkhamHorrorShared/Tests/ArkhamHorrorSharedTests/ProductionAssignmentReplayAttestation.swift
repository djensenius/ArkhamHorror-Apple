@testable import ArkhamHorrorShared
import Foundation

// swiftlint:disable file_length

struct AssignmentReplayServerBuildIdentity: Codable, Equatable, Sendable {
    let gitRevision: String
    let gitTree: String
    let sourceSHA256: String
    let sourceClean: Bool
    let attestation: String

    private enum CodingKeys: String, CodingKey {
        case gitRevision
        case gitTree
        case sourceSHA256 = "sourceSha256"
        case sourceClean
        case attestation
    }

    func validate() throws {
        guard gitRevision == ContractPin.current.backendCommit,
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  gitRevision,
                  count: 40
              ),
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  gitTree,
                  count: 40
              ),
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  sourceSHA256,
                  count: 64
              ),
              sourceClean,
              attestation == "git-clean"
        else {
            throw ProductionAssignmentReplayError.serverAttestationMismatch
        }
    }
}

struct AssignmentReplayServerValidatedPrompt: Codable, Equatable, Sendable {
    let questionVersion: Int
    let playerID: PlayerID
    let promptTag: String
    let promptSHA256: String

    private enum CodingKeys: String, CodingKey {
        case questionVersion
        case playerID = "playerId"
        case promptTag
        case promptSHA256 = "promptSha256"
    }

    func validate() throws {
        guard questionVersion > 0,
              questionVersion < Int.max,
              promptTag == BasicChoiceQuestionKind.questionWithSource.rawValue,
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  promptSHA256,
                  count: 64
              )
        else {
            throw ProductionAssignmentReplayError.serverAttestationMismatch
        }
    }
}

// swiftlint:disable:next type_name
struct AssignmentReplayServerValidatedCheckpoint: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let contractSchemaRevision: String
    let prompt: AssignmentReplayServerValidatedPrompt
    let checkpointGameSHA256: String
    let checkpointQueueSHA256: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case contractSchemaRevision
        case prompt
        case checkpointGameSHA256 = "checkpointGameSha256"
        case checkpointQueueSHA256 = "checkpointQueueSha256"
    }

    func validate() throws {
        try prompt.validate()
        guard schemaVersion == Self.schemaVersion,
              contractSchemaRevision ==
              ContractPin.current.supportedSchemaRevision.description,
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  checkpointGameSHA256,
                  count: 64
              ),
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  checkpointQueueSHA256,
                  count: 64
              )
        else {
            throw ProductionAssignmentReplayError.serverAttestationMismatch
        }
    }
}

struct AssignmentReplayAttestationRequest: Sendable {
    let serverProfile: ServerProfile
    let authToken: String
    let gameID: GameID
    let playerID: PlayerID
    let investigatorID: InvestigatorID
    let checkpointArtifactSHA256: String
}

struct AssignmentReplayPlayerRemapping: Codable, Equatable, Sendable {
    let investigatorID: InvestigatorID
    let checkpointPlayerID: PlayerID
    let importedPlayerID: PlayerID
    let livePlayerID: PlayerID
    let stateRemapped: Bool

    private enum CodingKeys: String, CodingKey {
        case investigatorID = "investigatorId"
        case checkpointPlayerID = "checkpointPlayerId"
        case importedPlayerID = "importedPlayerId"
        case livePlayerID = "livePlayerId"
        case stateRemapped
    }

    func validate() throws {
        guard stateRemapped
            ? livePlayerID == importedPlayerID
            : livePlayerID == checkpointPlayerID
        else {
            throw ProductionAssignmentReplayError.serverAttestationMismatch
        }
    }
}

private struct ReplayReceiptDigestPayload: Encodable {
    let schemaVersion: Int
    let gameID: GameID
    let gameGitRevision: String
    let backendBuild: AssignmentReplayServerBuildIdentity
    let checkpointSHA256: String
    let canonicalEnvelopeSHA256: String
    let validatedCheckpoint: AssignmentReplayServerValidatedCheckpoint
    let playerRemappings: [AssignmentReplayPlayerRemapping]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case gameID = "gameId"
        case gameGitRevision
        case backendBuild
        case checkpointSHA256 = "checkpointSha256"
        case canonicalEnvelopeSHA256 = "canonicalEnvelopeSha256"
        case validatedCheckpoint
        case playerRemappings
    }
}

struct AssignmentReplayImportReceipt: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let gameID: GameID
    let gameGitRevision: String
    let backendBuild: AssignmentReplayServerBuildIdentity
    let checkpointSHA256: String
    let canonicalEnvelopeSHA256: String
    let validatedCheckpoint: AssignmentReplayServerValidatedCheckpoint
    let playerRemappings: [AssignmentReplayPlayerRemapping]
    let receiptSHA256: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case gameID = "gameId"
        case gameGitRevision
        case backendBuild
        case checkpointSHA256 = "checkpointSha256"
        case canonicalEnvelopeSHA256 = "canonicalEnvelopeSha256"
        case validatedCheckpoint
        case playerRemappings
        case receiptSHA256 = "receiptSha256"
    }

    func computedSHA256() throws -> String {
        try LocaleCatalogLoader.sha256Hex(
            ContractJSON.encode(
                ReplayReceiptDigestPayload(
                    schemaVersion: schemaVersion,
                    gameID: gameID,
                    gameGitRevision: gameGitRevision,
                    backendBuild: backendBuild,
                    checkpointSHA256: checkpointSHA256,
                    canonicalEnvelopeSHA256: canonicalEnvelopeSHA256,
                    validatedCheckpoint: validatedCheckpoint,
                    playerRemappings: playerRemappings
                )
            )
        )
    }

    func validate(
        request: AssignmentReplayAttestationRequest,
        runningServerBuild: AssignmentReplayServerBuildIdentity
    ) throws {
        try backendBuild.validate()
        try validatedCheckpoint.validate()
        try playerRemappings.forEach { try $0.validate() }

        let investigatorIDs = playerRemappings.map(\.investigatorID)
        let checkpointPlayerIDs = playerRemappings.map(\.checkpointPlayerID)
        let expectedReceiptSHA256 = try computedSHA256()
        guard schemaVersion == Self.schemaVersion,
              gameID == request.gameID,
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  gameGitRevision,
                  count: 40
              ),
              backendBuild == runningServerBuild,
              checkpointSHA256 == request.checkpointArtifactSHA256,
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  checkpointSHA256,
                  count: 64
              ),
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  canonicalEnvelopeSHA256,
                  count: 64
              ),
              playerRemappings.count == 1,
              Set(investigatorIDs).count == investigatorIDs.count,
              Set(checkpointPlayerIDs).count == checkpointPlayerIDs.count,
              checkpointPlayerIDs.contains(
                  validatedCheckpoint.prompt.playerID
              ),
              playerRemappings[0].investigatorID == request.investigatorID,
              playerRemappings[0].checkpointPlayerID ==
              validatedCheckpoint.prompt.playerID,
              playerRemappings[0].importedPlayerID == request.playerID,
              playerRemappings[0].livePlayerID == request.playerID,
              playerRemappings[0].stateRemapped,
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  receiptSHA256,
                  count: 64
              ),
              receiptSHA256 == expectedReceiptSHA256
        else {
            throw ProductionAssignmentReplayError.serverAttestationMismatch
        }
    }
}

struct ProductionAssignmentReplayAttestation: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let gameID: GameID
    let gameGitRevision: String
    let checkpointSHA256: String
    let canonicalEnvelopeSHA256: String
    let validatedCheckpoint: AssignmentReplayServerValidatedCheckpoint
    let runningServerBuild: AssignmentReplayServerBuildIdentity
    let importReceipt: AssignmentReplayImportReceipt

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case gameID = "gameId"
        case gameGitRevision
        case checkpointSHA256 = "checkpointSha256"
        case canonicalEnvelopeSHA256 = "canonicalEnvelopeSha256"
        case validatedCheckpoint
        case runningServerBuild
        case importReceipt
    }

    var serverBuild: AssignmentReplayServerBuildIdentity {
        runningServerBuild
    }

    var gameRevision: String {
        gameGitRevision
    }

    var checkpointValidation: AssignmentReplayValidatedCheckpoint {
        AssignmentReplayValidatedCheckpoint(attestation: self)
    }

    func validate(request: AssignmentReplayAttestationRequest) throws {
        try runningServerBuild.validate()
        try validatedCheckpoint.validate()
        try importReceipt.validate(
            request: request,
            runningServerBuild: runningServerBuild
        )
        guard schemaVersion == Self.schemaVersion,
              gameID == request.gameID,
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  gameGitRevision,
                  count: 40
              ),
              checkpointSHA256 == request.checkpointArtifactSHA256,
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  checkpointSHA256,
                  count: 64
              ),
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  canonicalEnvelopeSHA256,
                  count: 64
              ),
              importReceipt.gameID == gameID,
              importReceipt.gameGitRevision == gameGitRevision,
              importReceipt.backendBuild == runningServerBuild,
              importReceipt.checkpointSHA256 == checkpointSHA256,
              importReceipt.canonicalEnvelopeSHA256 ==
              canonicalEnvelopeSHA256,
              importReceipt.validatedCheckpoint == validatedCheckpoint
        else {
            throw ProductionAssignmentReplayError.serverAttestationMismatch
        }
    }
}

struct AssignmentReplayAttestationClient: Sendable {
    static let maximumResponseBytes = 256 * 1024

    let transport: any HTTPTransport

    init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    func fetch(
        request context: AssignmentReplayAttestationRequest
    ) async throws -> ProductionAssignmentReplayAttestation {
        let url = try Self.attestationURL(context: context)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Token \(context.authToken)",
            forHTTPHeaderField: "Authorization"
        )

        let data = try await responseData(for: request, expectedURL: url)
        let attestation = try Self.decodeAttestation(data)
        try attestation.validate(request: context)
        return attestation
    }

    private func responseData(
        for request: URLRequest,
        expectedURL: URL
    ) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            try Task.checkCancellation()
            throw ProductionAssignmentReplayError.serverAttestationUnavailable
        }
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.url == expectedURL,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            throw ProductionAssignmentReplayError.serverAttestationUnavailable
        }
        guard data.count <= Self.maximumResponseBytes,
              Self.isJSONContentType(
                  httpResponse.value(forHTTPHeaderField: "Content-Type")
              )
        else {
            throw ProductionAssignmentReplayError.serverAttestationMalformed
        }
        return data
    }

    private static func decodeAttestation(
        _ data: Data
    ) throws -> ProductionAssignmentReplayAttestation {
        do {
            let original = try LosslessJSONParser.parse(
                data,
                maxByteCount: maximumResponseBytes
            )
            let attestation = try ContractJSON.decode(
                ProductionAssignmentReplayAttestation.self,
                from: data,
                maxByteCount: maximumResponseBytes
            )
            let reencoded = try LosslessJSONParser.parse(
                ContractJSON.encode(attestation),
                maxByteCount: maximumResponseBytes
            )
            guard original == reencoded else {
                throw ProductionAssignmentReplayError
                    .serverAttestationMalformed
            }
            return attestation
        } catch {
            throw ProductionAssignmentReplayError.serverAttestationMalformed
        }
    }

    private static func isJSONContentType(_ rawValue: String?) -> Bool {
        guard let rawValue,
              rawValue.utf8.allSatisfy({ $0 < 0x80 })
        else {
            return false
        }
        let mediaType = rawValue
            .split(
                separator: ";",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )[0]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return mediaType == "application/json"
    }

    private static func attestationURL(
        context: AssignmentReplayAttestationRequest
    ) throws -> URL {
        do {
            return try GameLifecycleService.gameURL(
                context.gameID,
                suffix: "/replay-attestation",
                on: context.serverProfile,
                pin: .current
            )
        } catch {
            throw ProductionAssignmentReplayError.serverAttestationMalformed
        }
    }
}
