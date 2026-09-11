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

struct ProductionAssignmentReplayAttestation: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let gameID: GameID
    let playerID: PlayerID
    let checkpointPlayerID: PlayerID
    let serverBuild: AssignmentReplayServerBuildIdentity
    let gameRevision: String
    let checkpointArtifactSHA256: String
    let checkpointEnvelopeSHA256: String
    let contractRevision: String
    let checkpointName: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case gameID = "gameId"
        case playerID = "playerId"
        case checkpointPlayerID = "checkpointPlayerId"
        case serverBuild
        case gameRevision
        case checkpointArtifactSHA256 = "checkpointArtifactSha256"
        case checkpointEnvelopeSHA256 = "checkpointEnvelopeSha256"
        case contractRevision
        case checkpointName
    }

    func validate(
        configuration: ProductionAssignmentReplayConfiguration
    ) throws {
        let checkpoint = configuration.checkpointArtifact
        try serverBuild.validate()
        guard schemaVersion == Self.schemaVersion,
              gameID == configuration.promptIdentity.gameID,
              playerID == configuration.promptIdentity.ownerID,
              checkpointPlayerID == checkpoint.playerID,
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  gameRevision,
                  count: 40
              ),
              gameRevision == checkpoint.sourceGameRevision,
              checkpointArtifactSHA256 == checkpoint.artifactSHA256,
              checkpointEnvelopeSHA256 == checkpoint.envelopeSHA256,
              contractRevision ==
              ContractPin.current.supportedSchemaRevision.description,
              contractRevision == checkpoint.contractRevision,
              checkpointName == checkpoint.checkpointName
        else {
            throw ProductionAssignmentReplayError.serverAttestationMismatch
        }
    }
}

struct AssignmentReplayAttestationClient: Sendable {
    private static let maximumResponseBytes = 256 * 1024

    let transport: any HTTPTransport

    init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    func fetch(
        configuration: ProductionAssignmentReplayConfiguration
    ) async throws -> ProductionAssignmentReplayAttestation {
        let url = try Self.attestationURL(configuration: configuration)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Token \(configuration.authToken)",
            forHTTPHeaderField: "Authorization"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
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
        try attestation.validate(configuration: configuration)
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
                  "checkpointPlayerId",
                  "serverBuild",
                  "gameRevision",
                  "checkpointArtifactSha256",
                  "checkpointEnvelopeSha256",
                  "contractRevision",
                  "checkpointName",
              ],
              case let .object(serverBuild)? = root["serverBuild"],
              Set(serverBuild.keys) == [
                  "gitRevision",
                  "gitTree",
                  "sourceSha256",
                  "sourceClean",
                  "attestation",
              ]
        else {
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
        configuration: ProductionAssignmentReplayConfiguration
    ) throws -> URL {
        do {
            return try GameLifecycleService.gameURL(
                configuration.promptIdentity.gameID,
                suffix: "/replay-attestation",
                on: configuration.serverProfile,
                pin: .current
            )
        } catch {
            throw ProductionAssignmentReplayError.serverAttestationMalformed
        }
    }
}
