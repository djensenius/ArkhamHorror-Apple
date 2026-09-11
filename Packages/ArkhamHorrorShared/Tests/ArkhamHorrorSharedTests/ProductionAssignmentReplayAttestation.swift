@testable import ArkhamHorrorShared
import Foundation

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

struct AssignmentReplayAttestationRequest: Sendable {
    let serverProfile: ServerProfile
    let authToken: String
    let gameID: GameID
    let playerID: PlayerID
    let checkpointArtifactSHA256: String
}

struct ProductionAssignmentReplayAttestation: Codable, Equatable, Sendable {
    static let schemaVersion = 2

    let schemaVersion: Int
    let gameID: GameID
    let playerID: PlayerID
    let serverBuild: AssignmentReplayServerBuildIdentity
    let gameRevision: String
    let checkpointValidation: AssignmentReplayValidatedCheckpoint

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case gameID = "gameId"
        case playerID = "playerId"
        case serverBuild
        case gameRevision
        case checkpointValidation
    }

    func validate(request: AssignmentReplayAttestationRequest) throws {
        try serverBuild.validate()
        try checkpointValidation.validate(runningServerBuild: serverBuild)
        guard schemaVersion == Self.schemaVersion,
              gameID == request.gameID,
              playerID == request.playerID,
              checkpointValidation.artifactSHA256 ==
              request.checkpointArtifactSHA256,
              gameRevision == checkpointValidation.sourceGameRevision
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
              httpResponse.url == url,
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
        try Self.validateJSONShape(data)
        let attestation: ProductionAssignmentReplayAttestation
        do {
            attestation = try ContractJSON.decode(
                ProductionAssignmentReplayAttestation.self,
                from: data,
                maxByteCount: Self.maximumResponseBytes
            )
        } catch {
            throw ProductionAssignmentReplayError.serverAttestationMalformed
        }
        try attestation.validate(request: context)
        return attestation
    }

    private static func validateJSONShape(_ data: Data) throws {
        let value: JSONValue
        do {
            value = try ContractJSON.decode(
                JSONValue.self,
                from: data,
                maxByteCount: maximumResponseBytes
            )
        } catch {
            throw ProductionAssignmentReplayError.serverAttestationMalformed
        }
        guard case let .object(root) = value,
              Set(root.keys) == [
                  "schemaVersion",
                  "gameId",
                  "playerId",
                  "serverBuild",
                  "gameRevision",
                  "checkpointValidation",
              ],
              Self.hasExactBuildShape(root["serverBuild"]),
              case let .object(validation)? = root["checkpointValidation"],
              Set(validation.keys) == [
                  "validator",
                  "validationStatus",
                  "artifactSha256",
                  "canonicalEnvelopeSha256",
                  "replayBuild",
                  "contractRevision",
                  "sourceGameRevision",
                  "checkpointName",
                  "checkpointPlayerId",
                  "questionVersion",
                  "promptTag",
                  "promptSha256",
              ],
              Self.hasExactBuildShape(validation["replayBuild"])
        else {
            throw ProductionAssignmentReplayError.serverAttestationMalformed
        }
    }

    private static func hasExactBuildShape(_ value: JSONValue?) -> Bool {
        guard case let .object(build)? = value else { return false }
        return Set(build.keys) == [
            "gitRevision",
            "gitTree",
            "sourceSha256",
            "sourceClean",
            "attestation",
        ]
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
